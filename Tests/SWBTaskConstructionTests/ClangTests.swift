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

import struct Foundation.Data
import Foundation

import Testing
import SWBTestSupport
import SWBCore
import SWBProtocol
import SWBUtil

import SWBTaskConstruction

/// Tests of specific `clang` behavior we feel are worth testing (e.g., because they've regressed in the past, or
@Suite
fileprivate struct ClangTests: CoreBasedTests {
    /// Test that values of `CLANG_CXX_LIBRARY` work as expected.  We no longer pass `-stdlib=libstdc++` as of Xcode 13.3. We would like to not pass `-stdlib=` at all and just rely on the compiler default, but a few issues prevent us from doing so at this time.
    ///
    /// - remark: See <rdar://83768231&86344993> for more details.
    @Test(.requireSDKs(.host))
    func cPlusPlusLibrary() async throws {
        func getTestProject(cppLibrarySetting: String) -> TestProject {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("ClassOne.cpp"),
                        TestFile("Info.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGN_IDENTITY": "-",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_CXX_LIBRARY": cppLibrarySetting,
                            "CLANG_USE_RESPONSE_FILE": "NO"
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "CommandLineToolTarget",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "Info.plist"]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "ClassOne.cpp",
                            ]),
                            TestFrameworksBuildPhase([
                            ]),
                        ]
                    ),
                ])
            return testProject
        }
        let core = try await getCore()

        // Test with an empty setting (the default): -stdlib= should not be passed in this case.
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(cppLibrarySetting: "")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .host, fs: fs) { results in
                results.checkTarget("CommandLineToolTarget") { target -> Void in
                    // Check the compile task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkCommandLineNoMatch([.prefix("-stdlib=")])
                    }

                    // Check the link task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineNoMatch([.prefix("-stdlib=")])
                    }

                    // Check issues.
                    results.checkNoDiagnostics()
                }
            }
        }

        // Test with the setting set to libc++ (which clang supports): -stdlib=libc++ should be passed in this case.
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(cppLibrarySetting: "libc++")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .host, fs: fs) { results in
                results.checkTarget("CommandLineToolTarget") { target -> Void in
                    // Check the compile task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkCommandLineContains(["-stdlib=libc++"])
                    }

                    // Check the link task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-stdlib=libc++"])
                    }

                    // Check issues.
                    results.checkNoDiagnostics()
                }
            }
        }

        // Test with the setting set to libstdc++ (which clang does not support): -stdlib= should not be passed in this case.
        do {
            let fs = PseudoFS()
            let testProject = getTestProject(cppLibrarySetting: "libstdc++")
            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(runDestination: .host, fs: fs) { results in
                results.checkTarget("CommandLineToolTarget") { target -> Void in
                    // Check the compile task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkCommandLineNoMatch([.prefix("-stdlib=")])
                    }

                    // Check the link task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineNoMatch([.prefix("-stdlib=")])
                    }

                    // Check issues.
                    results.checkWarning(.equal("CLANG_CXX_LIBRARY is set to \'libstdc++\': The 'libstdc++' C++ Standard Library is no longer available, and this setting can be removed. (in target 'CommandLineToolTarget' from project 'aProject')"))
                    results.checkNoErrors()
                }
            }
        }
    }

    @Test(.skipHostOS(.windows, "clang-cache is not available on Windows"), .skipHostOS(.linux, "test is incompatible with linux fallback system toolchain mechanism"), .requireSDKs(.host))
    func clangCacheEnableLauncher() async throws {
        let runDestination: RunDestinationInfo = .host
        let clangCachePath: String = switch runDestination {
        case .macOS:
            "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang-cache"
        default:
            "usr/bin/clang-cache"
        }
        let mockClangPath: String = "/mytoolchain/bin/clang"

        func getTestProject(_ extraSettings: [String: String] = [:]) -> TestProject {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("test.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_CACHE_ENABLE_LAUNCHER": "YES",
                        ].addingContents(of: extraSettings)),
                ],
                targets: [
                    TestStandardTarget(
                        "ToolTarget",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "test.c",
                            ]),
                        ]
                    ),
                ])
            return testProject
        }
        let core = try await getCore()

        // We're using a PseudoFS so we can't actually execute the clang binary; use a custom client delegate to intercept that call.
        final class ClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            let mockClangPath: String

            init(_ mockClangPath: String) {
                self.mockClangPath = Path(mockClangPath).str
                super.init()
            }

            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first == mockClangPath {
                    return .result(status: .exit(0), stdout: Data(), stderr: Data())
                }
                return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
            }
        }

        do {
            let fs = PseudoFS()
            try await fs.writeFileContents(clangCompilerPath) { $0 <<< "binary" }
            let tester = try TaskConstructionTester(core, getTestProject())

            await tester.checkBuild(runDestination: .host, fs: fs) { results in
                results.checkError(.contains("'clang-cache' was not found next to compiler"))
            }
        }
        do {
            let fs = PseudoFS()
            try await fs.writeFileContents(Path(mockClangPath)) { $0 <<< "binary" }
            try await fs.writeFileContents(core.developerPath.path.join(clangCachePath)) { $0 <<< "binary" }
            let tester = try TaskConstructionTester(core, getTestProject(["CC" : Path(mockClangPath).str]))

            await tester.checkBuild(runDestination: .host, fs: fs, clientDelegate: ClientDelegate(mockClangPath)) { results in
                results.checkError(.contains("'clang-cache' was not found next to compiler"))
            }
        }
        do {
            let fs = PseudoFS()
            try await fs.writeFileContents(clangCompilerPath) { $0 <<< "binary" }
            let tester = try TaskConstructionTester(core, getTestProject(["CLANG_CACHE_FALLBACK_IF_UNAVAILABLE" : "YES"]))

            await tester.checkBuild(runDestination: .host, fs: fs) { results in
                results.checkTarget("ToolTarget") { target -> Void in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkCommandLineMatches([.suffix(Path("usr/bin/clang").str)])
                        task.checkCommandLineNoMatch([.suffix("clang-cache")])
                    }
                    results.checkNoErrors()
                }
            }
        }
        do {
            let fs = PseudoFS()
            try await fs.writeFileContents(Path(mockClangPath)) { $0 <<< "binary" }
            try await fs.writeFileContents(core.developerPath.path.join(clangCachePath)) { $0 <<< "binary" }
            let tester = try TaskConstructionTester(core, getTestProject([
                "CC" : Path(mockClangPath).str,
                "CLANG_CACHE_FALLBACK_IF_UNAVAILABLE" : "YES",
            ]))

            await tester.checkBuild(runDestination: .host, fs: fs, clientDelegate: ClientDelegate(mockClangPath)) { results in
                results.checkTarget("ToolTarget") { target -> Void in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkCommandLineMatches([.equal(Path(mockClangPath).str)])
                        task.checkCommandLineNoMatch([.suffix("clang-cache")])
                    }
                    results.checkNoErrors()
                }
            }
        }
        do {
            let fs = PseudoFS()
            try await fs.writeFileContents(clangCompilerPath) { $0 <<< "binary" }
            try await fs.writeFileContents(core.developerPath.path.join(clangCachePath)) { $0 <<< "binary" }
            let tester = try TaskConstructionTester(core, getTestProject())

            await tester.checkBuild(runDestination: .host, fs: fs) { results in
                results.checkTarget("ToolTarget") { target -> Void in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkCommandLineMatches([.suffix(Path("usr/bin/clang-cache").str), .suffix(Path("usr/bin/clang").str)])
                    }
                    results.checkNoErrors()
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func workingDirectoryOverride() async throws {
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        var workingDirectory = Path("/tmp/Test/aProject")
        if runDestination == .windows {
            // Get the current drive and add the tmp project path
            let currentDirectoryPath = FileManager.default.currentDirectoryPath
            workingDirectory = Path(currentDirectoryPath.prefix(3)).join("tmp/Test/aProject")
        }
        let overrideWorkingDirectory = runDestination == .windows ? Path("C:/foo/bar") : Path("/foo/bar")

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("test.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "LIBTOOL": libtoolPath.str,
                    ])
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "test.c",
                        ]),
                    ]
                ),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .host) { results in
            results.checkTask(.matchRuleType("CompileC")) { task in
                #expect(task.workingDirectory == workingDirectory)
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["COMPILER_WORKING_DIRECTORY": overrideWorkingDirectory.str]), runDestination: .host) { results in
            results.checkTask(.matchRuleType("CompileC")) { task in
                #expect(task.workingDirectory == overrideWorkingDirectory)
            }
        }
    }
}
