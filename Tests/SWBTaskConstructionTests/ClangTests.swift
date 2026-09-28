//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025-2026 Apple Inc. and the Swift project authors
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
import enum SWBProtocol.ExternalToolResult
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

    @Test(
        .requireSDKs(.host),
        .requireXcode27(),
        .skipHostOS(.windows, "clang-cache is not available on Windows"),
        .skipHostOS(.linux, "test is incompatible with fallback system toolchain mechanism"),
        .skipHostOS(.freebsd, "test is incompatible with fallback system toolchain mechanism"),
        .skipHostOS(.openbsd, "test is incompatible with fallback system toolchain mechanism"),
    )
    func clangCacheEnableLauncher() async throws {
        let runDestination = RunDestinationInfo.host
        let clangCachePath: String = switch runDestination {
        // There are multiple macOS run destinations and not all of them match .macOS, so we check the platform instead.
        case _ where runDestination.platform == "macosx":
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

            init(hostOS: OperatingSystem, _ mockClangPath: String) {
                self.mockClangPath = Path(mockClangPath).str
                super.init(hostOS: hostOS)
            }

            override func executeExternalTool(commandLine: [String], workingDirectory: Path?, environment: [String : String]) async throws -> ExternalToolResult {
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

            await tester.checkBuild(runDestination: runDestination, fs: fs) { results in
                results.checkError(.contains("'clang-cache' was not found next to compiler"))
            }
        }
        do {
            let fs = PseudoFS()
            try await fs.writeFileContents(Path(mockClangPath)) { $0 <<< "binary" }
            try await fs.writeFileContents(core.developerPath.path.join(clangCachePath)) { $0 <<< "binary" }
            let tester = try TaskConstructionTester(core, getTestProject(["CC" : Path(mockClangPath).str]))

            await tester.checkBuild(runDestination: runDestination, fs: fs, clientDelegate: ClientDelegate(hostOS: core.hostOperatingSystem, mockClangPath)) { results in
                results.checkError(.contains("'clang-cache' was not found next to compiler"))
            }
        }
        do {
            let fs = PseudoFS()
            try await fs.writeFileContents(clangCompilerPath) { $0 <<< "binary" }
            let tester = try TaskConstructionTester(core, getTestProject(["CLANG_CACHE_FALLBACK_IF_UNAVAILABLE" : "YES"]))

            await tester.checkBuild(runDestination: runDestination, fs: fs) { results in
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

            await tester.checkBuild(runDestination: runDestination, fs: fs, clientDelegate: ClientDelegate(hostOS: core.hostOperatingSystem, mockClangPath)) { results in
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

            await tester.checkBuild(runDestination: runDestination, fs: fs) { results in
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


    @Test(.requireSDKs(.host))
    func indexOptions() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "ProjectName",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.c")
                    ]),
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "COMPILER_INDEX_STORE_ENABLE": "YES",
                                    "INDEX_DATA_STORE_DIR": tmpDir.join("index").str,
                                    "INDEX_STORE_COMPRESS": "YES",
                                    "INDEX_STORE_ONLY_PROJECT_FILES": "YES",
                                    "CLANG_INDEX_STORE_IGNORE_MACROS": "YES",
                                    "INDEX_STORE_CODEGEN_NAME": "YES",
                                ]
                            ),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["INDEX_ENABLE_DATA_STORE": "YES"]), runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    compileTask.checkCommandLineContains(["-index-store-path"])
                    compileTask.checkCommandLineContains(["-index-store-compress"])
                    compileTask.checkCommandLineContains(["-index-ignore-system-symbols"])
                    compileTask.checkCommandLineContains(["-index-ignore-pcms"])
                    compileTask.checkCommandLineContains(["-index-ignore-macros"])
                    compileTask.checkCommandLineContains(["-index-record-codegen-name"])
                }
            }
            // Check that we don't emit any index-related options when INDEX_ENABLE_DATA_STORE is not enabled
            await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: [:]), runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    compileTask.checkCommandLineDoesNotContain("-index-store-path")
                    compileTask.checkCommandLineDoesNotContain("-index-store-compress")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-system-symbols")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-pcms")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-macros")
                    compileTask.checkCommandLineDoesNotContain("-index-record-codegen-name")
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func indexOptionsNotAddedIfIndexingIsDisabled() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "ProjectName",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.c")
                    ]),
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "COMPILER_INDEX_STORE_ENABLE": "NO",
                                    "INDEX_DATA_STORE_DIR": tmpDir.join("index").str,
                                    "INDEX_STORE_COMPRESS": "YES",
                                    "INDEX_STORE_ONLY_PROJECT_FILES": "YES",
                                    "CLANG_INDEX_STORE_IGNORE_MACROS": "YES",
                                    "OTHER_CFLAGS": "-DCLANG_INDEX_STORE_ENABLE=$(CLANG_INDEX_STORE_ENABLE) -DCOMPILER_INDEX_STORE_ENABLE=$(COMPILER_INDEX_STORE_ENABLE)"
                                ]
                            ),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["INDEX_ENABLE_DATA_STORE": "YES"]), runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    compileTask.checkCommandLineDoesNotContain("-index-store-path")
                    compileTask.checkCommandLineDoesNotContain("-index-store-compress")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-system-symbols")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-pcms")
                    compileTask.checkCommandLineDoesNotContain("-index-ignore-macros")
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func indexOptionsRequireClangSupport() async throws {
        let clangInfo = try await self.clangInfo
        let supportsIndexWhileBuilding = clangInfo.isAppleClang || clangInfo.toolFeatures.has(.indexUnitOutputPath)

        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "ProjectName",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.c")
                    ]),
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "COMPILER_INDEX_STORE_ENABLE": "YES",
                                    "INDEX_DATA_STORE_DIR": tmpDir.join("index").str,
                                    "CC": clangInfo.toolPath.str,
                                ]
                            ),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["INDEX_ENABLE_DATA_STORE": "YES"]), runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    if supportsIndexWhileBuilding {
                        compileTask.checkCommandLineContainsUninterrupted(["-index-store-path", tmpDir.join("index").str])
                    } else {
                        compileTask.checkCommandLineDoesNotContain("-index-store-path")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.host), .requireClangFeatures(.invokeSsaf))
    func invokeSsafOptions() async throws {
        func getTestProject(invokeSSAF: String, extractSummaries: String = "", stopAtLUSummaryGeneration: String = "", sourceTransformation: String = "") -> TestProject {
            TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "INVOKE_SSAF": invokeSSAF,
                            "EXTRACT_SUMMARIES": extractSummaries,
                            "STOP_AT_LU_SUMMARY_GENERATION": stopAtLUSummaryGeneration,
                            "SOURCE_TRANSFORMATION": sourceTransformation,
                            // Uncomment to test with a local build of clang
                            // "CC": "<LOCAL_CLANG_PATH>/bin/clang",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .dynamicLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.c"]),
                        ]
                    ),
                ])
        }

        let core = try await getCore()

        // When INVOKE_SSAF is YES, the extract-summaries value and a .ssaf-tu.json summary file path are added.
        // The summary file is co-located with the object file: same directory, same basename, .ssaf-tu.json extension.
        // With SOURCE_TRANSFORMATION also set, a TransformSource task should be created to apply it once the
        // global analysis result is available.
        do {
            let tester = try TaskConstructionTester(core, getTestProject(invokeSSAF: "YES", extractSummaries: "CallGraph,UnsafeBufferUsage", stopAtLUSummaryGeneration: "CallGraph", sourceTransformation: "UnsafeBufferUsage"))
            await tester.checkBuild(runDestination: .host) { results in
                var objectPath: Path? = nil
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains(["--ssaf-extract-summaries=CallGraph,UnsafeBufferUsage"])
                    objectPath = task.outputs.map({ $0.path }).first(where: { $0.str.hasSuffix(".o") })
                    if let objectPath {
                        let expectedJsonPath = objectPath.dirname.join(objectPath.basenameWithoutSuffix + ".ssaf-tu.json").str
                        task.checkCommandLineContains(["--ssaf-tu-summary-file=\(expectedJsonPath)"])
                    } else {
                        Issue.record("No .o output found in CompileC task outputs")
                    }
                }
                // The entity linker task should receive the .ssaf-tu.json summary matching File1.c as input
                // and produce a .linked-summaries.json output.
                var linkedSummariesPath: Path? = nil
                results.checkTask(.matchRuleType("LinkEntity")) { task in
                    let jsonInputs = task.inputs.filter { $0.path.fileExtension == "json" }
                    if let jsonInput = jsonInputs.first {
                        #expect(jsonInput.path.basenameWithoutSuffix == "File1.ssaf-tu")
                    } else {
                        Issue.record("Expected File1.ssaf-tu.json as input to the LinkEntity task")
                    }
                    linkedSummariesPath = task.outputs.map({ $0.path }).first(where: { $0.str.hasSuffix(".linked-summaries.json") })
                    #expect(linkedSummariesPath != nil)
                }
                //
                var analyzerOutputPath: Path? = nil
                results.checkTask(.matchRuleType("AnalyzeSSAF")) { task in
                    task.checkCommandLineDoesNotContain("CallGraphAnalysisResult")
                    task.checkCommandLineContains(["-a", "UnsafeBufferUsageAnalysisResult"])
                    let jsonInputs = task.inputs.filter { $0.path.str.hasSuffix(".linked-summaries.json") }
                    if let jsonInput = jsonInputs.first {
                        #expect(jsonInput.path.basename == "Test.dylib.linked-summaries.json")
                    } else {
                        Issue.record("Expected Test.dylib.linked-summaries.json as input to the AnalyzeSSAF task")
                    }
                    analyzerOutputPath = task.outputs.map({ $0.path }).first(where: { $0.str.hasSuffix(".ssaf-analysis.json") })
                    #expect(analyzerOutputPath != nil)
                }

                // The TransformSource task re-invokes clang to apply SOURCE_TRANSFORMATION once the analysis
                // result is available.
                guard let objectPath, let analyzerOutputPath, let linkedSummariesPath else {
                    Issue.record("Expected a CompileC .o output, an AnalyzeSSAF .ssaf-analysis.json output, and a LinkEntity .linked-summaries.json output")
                    return
                }
                let srcEditFile = objectPath.dirname.join(objectPath.basenameWithoutSuffix + ".ssaf-edit.yaml")
                let transformationReportFile = objectPath.dirname.join(objectPath.basenameWithoutSuffix + ".ssaf-report.sarif.json")
                results.checkTask(.matchRuleType("TransformSource")) { task in
                    task.checkCommandLineContains([
                        "--ssaf-source-transformation=UnsafeBufferUsage",
                        "--ssaf-global-scope-analysis-result=\(analyzerOutputPath.str)",
                        "--ssaf-src-edit-file=\(srcEditFile.str)",
                        "--ssaf-transformation-report-file=\(transformationReportFile.str)",
                        "--ssaf-compilation-unit-id=\(objectPath.str)",
                        // The link unit ID must match the namespace clang-ssaf-linker assigned the LU
                        // summary it produced for this arch: the stem of its own output path.
                        "--ssaf-link-unit-id=\(linkedSummariesPath.basenameWithoutSuffix)",
                    ])

                    task.checkCommandLineNoMatch([.prefix("--ssaf-extract-summaries=")])
                    task.checkCommandLineNoMatch([.prefix("--ssaf-tu-summary-file=")])
                    #expect(task.commandLine.filter({ $0.asString.hasPrefix("--ssaf-compilation-unit-id=") }).count == 1)
                    #expect(task.commandLine.filter({ $0.asString.hasPrefix("--ssaf-link-unit-id=") }).count == 1)

                    task.checkCommandLineDoesNotContain("-o")
                    task.checkCommandLineDoesNotContain(objectPath.str)

                    let outputPaths = task.outputs.map(\.path)
                    #expect(outputPaths.contains(srcEditFile))
                    #expect(outputPaths.contains(transformationReportFile))
                }

                // The MergeSourceEdits task should receive the .ssaf-edit.yaml produced by TransformSource
                // as input and merge it into a single output next to the product.
                results.checkTask(.matchRuleType("MergeSourceEdits")) { task in
                    #expect(task.inputs.map(\.path).contains(srcEditFile))
                    let mergeOutput = task.outputs.map(\.path).first(where: { $0.str.hasSuffix(".yaml") && $0.basename.hasPrefix("Test-merged-src-edits-") })
                    #expect(mergeOutput != nil)
                    if let mergeOutput {
                        task.checkCommandLineContains([srcEditFile.str, "-o", mergeOutput.str])
                    }
                }
                results.checkNoDiagnostics()
            }
        }

        // When INVOKE_SSAF is NO, neither ssaf flag is present and no entity linker task is created.
        do {
            let tester = try TaskConstructionTester(core, getTestProject(invokeSSAF: "NO"))
            await tester.checkBuild(runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineNoMatch([.prefix("--ssaf-extract-summaries=")])
                    task.checkCommandLineNoMatch([.prefix("--ssaf-tu-summary-file=")])
                }
                results.checkNoTask(.matchRuleType("LinkEntity"))
                results.checkNoTask(.matchRuleType("AnalyzeSSAF"))
                results.checkNoTask(.matchRuleType("MergeSourceEdits"))
                results.checkNoDiagnostics()
            }
        }

        // The value of EXTRACT_SUMMARIES is passed through verbatim to --ssaf-extract-summaries.
        // With SOURCE_TRANSFORMATION left empty, no TransformSource task should be created even though
        // INVOKE_SSAF is enabled.
        do {
            let tester = try TaskConstructionTester(core, getTestProject(invokeSSAF: "YES", extractSummaries: "CallGraph,UnsafeBufferUsage"))
            await tester.checkBuild(runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains(["--ssaf-extract-summaries=CallGraph,UnsafeBufferUsage"])
                }
                results.checkNoTask(.matchRuleType("TransformSource"))
                results.checkNoTask(.matchRuleType("MergeSourceEdits"))
                results.checkNoDiagnostics()
            }
        }
    }

    /// For a target building more than one base architecture, each arch's TU summaries must be linked (and
    /// analyzed) separately, and (when `SSAF_MULTI_ARCH_CREATE` is enabled) the per-arch linked-summaries
    /// bundles merged into one multi-arch bundle at the target's canonical location -- mirroring how per-arch
    /// binaries are lipo'd into a universal binary.
    @Test(.requireSDKs(.macOS), .requireClangFeatures(.invokeSsaf))
    func invokeSsafMultiArch() async throws {
        func getTestProject(multiArchCreate: String) -> TestProject {
            TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "INVOKE_SSAF": "YES",
                            "EXTRACT_SUMMARIES": "CallGraph",
                            "ARCHS": "x86_64 arm64",
                            "MACOSX_DEPLOYMENT_TARGET": "12.0",
                            "SSAF_MULTI_ARCH_CREATE": multiArchCreate,
                            // Uncomment to test with a local build of clang
                            // "CC": "<LOCAL_CLANG_PATH>/bin/clang",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .dynamicLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.c"]),
                        ]
                    ),
                ])
        }

        let core = try await getCore()

        // SSAF_MULTI_ARCH_CREATE defaults to YES: the per-arch linked-summaries bundles are merged into one
        // multi-arch bundle at the target's canonical location.
        do {
            let tester = try TaskConstructionTester(core, getTestProject(multiArchCreate: ""))
            await tester.checkBuild(runDestination: .anyMac) { results in
                // There should be one LinkEntity task per arch, plus one that bundles them together.
                var perArchLinkOutputs = Set<Path>()
                results.checkTasks(.matchRuleType("LinkEntity")) { tasks in
                    let allTasks = Array(tasks)
                    #expect(allTasks.count == 3)

                    let perArchTasks = allTasks.filter { !$0.commandLineAsStrings.contains("multi-arch") }
                    #expect(perArchTasks.count == 2)
                    for task in perArchTasks {
                        let tuInputs = task.inputs.filter { $0.path.str.hasSuffix(".ssaf-tu.json") }
                        #expect(tuInputs.count == 1)
                        if let output = task.outputs.map({ $0.path }).first(where: { $0.str.hasSuffix(".linked-summaries.json") }) {
                            perArchLinkOutputs.insert(output)
                        } else {
                            Issue.record("Expected a .linked-summaries.json output from per-arch LinkEntity task")
                        }
                    }
                    // The two per-arch outputs must be distinct locations.
                    #expect(perArchLinkOutputs.count == 2)

                    let mergeTasks = allTasks.filter { $0.commandLineAsStrings.contains("multi-arch") }
                    #expect(mergeTasks.count == 1)
                    if let mergeTask = mergeTasks.first {
                        mergeTask.checkCommandLineContains(["multi-arch", "create"])
                        let summaryInputs = Set(mergeTask.inputs.map(\.path).filter { $0.str.hasSuffix(".linked-summaries.json") })
                        #expect(summaryInputs == perArchLinkOutputs)
                        #expect(mergeTask.outputs.map(\.path).contains(where: { $0.basename == "Test.dylib.linked-summaries.json" }))
                    }
                }

                // Each arch analyzes its own linked-summaries bundle: clang-ssaf-analyzer reads a single-triple
                // link unit summary, not the merged multi-arch bundle.
                results.checkTasks(.matchRuleType("AnalyzeSSAF")) { tasks in
                    let allTasks = Array(tasks)
                    #expect(allTasks.count == 2)
                    var analyzedInputs = Set<Path>()
                    for task in allTasks {
                        let jsonInputs = task.inputs.filter { $0.path.str.hasSuffix(".linked-summaries.json") }
                        #expect(jsonInputs.count == 1)
                        if let jsonInput = jsonInputs.first {
                            analyzedInputs.insert(jsonInput.path)
                        }
                    }
                    #expect(analyzedInputs == perArchLinkOutputs)
                }

                results.checkNoDiagnostics()
            }
        }

        // With SSAF_MULTI_ARCH_CREATE=NO, only the per-arch LinkEntity/AnalyzeSSAF tasks are created; no
        // multi-arch bundle is produced (e.g. for a toolchain whose clang-ssaf-linker predates `multi-arch create`).
        do {
            let tester = try TaskConstructionTester(core, getTestProject(multiArchCreate: "NO"))
            await tester.checkBuild(runDestination: .anyMac) { results in
                results.checkTasks(.matchRuleType("LinkEntity")) { tasks in
                    let allTasks = Array(tasks)
                    #expect(allTasks.count == 2)
                    #expect(allTasks.allSatisfy { !$0.commandLineAsStrings.contains("multi-arch") })
                }
                results.checkTasks(.matchRuleType("AnalyzeSSAF")) { tasks in
                    #expect(Array(tasks).count == 2)
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// A static library dependency's own TU summaries should be bundled unresolved (via
    /// `static-library create`) so a dependent target's own entity-linker step can fold them in
    /// alongside its own TU summaries, mirroring how real object-file linking folds in a static
    /// archive's members.
    @Test(.requireSDKs(.host), .requireClangFeatures(.invokeSsaf))
    func invokeSsafStaticLibraryDependency() async throws {
        let libtoolPath = try await self.libtoolPath
        func getTestProject(libraryInvokesSSAF: String) -> TestProject {
            TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("LibFile.c"),
                        TestFile("File1.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "INVOKE_SSAF": "YES",
                            "EXTRACT_SUMMARIES": "CallGraph",
                            "LIBTOOL": libtoolPath.str,
                        ]),
                ],
                targets: [
                    // "Test" must be declared first: TaskConstructionTester.checkBuild() with no
                    // explicit targetName builds only project.targets[0] (plus its dependencies
                    // transitively), so the target actually under test needs to be first, not its
                    // dependency.
                    TestStandardTarget(
                        "Test",
                        type: .dynamicLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["File1.c"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("StaticLib"))]),
                        ],
                        dependencies: ["StaticLib"]
                    ),

                    TestStandardTarget(
                        "StaticLib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: ["INVOKE_SSAF": libraryInvokesSSAF]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["LibFile.c"]),
                        ]
                    ),
                ])
        }

        let core = try await getCore()

        // Positive case: StaticLib also has INVOKE_SSAF=YES.
        do {
            let tester = try TaskConstructionTester(core, getTestProject(libraryInvokesSSAF: "YES"))
            await tester.checkBuild(runDestination: .host) { results in
                // StaticLib gets both its usual flat LinkEntity task and a `static-library create`
                // one that bundles only its own TU summaries, unresolved.
                var staticLibSidecar: Path? = nil
                results.checkTasks(.matchTargetName("StaticLib"), .matchRuleType("LinkEntity")) { tasks in
                    let allTasks = Array(tasks)
                    #expect(allTasks.count == 2)

                    let flatLinkTasks = allTasks.filter { !$0.commandLineAsStrings.contains("static-library") }
                    #expect(flatLinkTasks.count == 1)

                    let staticLibraryTasks = allTasks.filter { $0.commandLineAsStrings.contains("static-library") }
                    #expect(staticLibraryTasks.count == 1)
                    if let staticLibraryTask = staticLibraryTasks.first {
                        staticLibraryTask.checkCommandLineContains(["static-library", "create"])
                        let tuInputs = staticLibraryTask.inputs.filter { $0.path.str.hasSuffix(".ssaf-tu.json") }
                        #expect(tuInputs.count == 1)
                        staticLibSidecar = staticLibraryTask.outputs.map(\.path).first(where: { $0.str.hasSuffix(".ssaf-staticlib.json") })
                    }
                }

                // Test's own flat link should include StaticLib's .ssaf-staticlib.json as an extra
                // input, and pin --target-triple explicitly because of it.
                results.checkTask(.matchTargetName("Test"), .matchRuleType("LinkEntity")) { task in
                    guard let staticLibSidecar else {
                        Issue.record("Expected StaticLib to produce a .ssaf-staticlib.json sidecar")
                        return
                    }
                    #expect(task.inputs.map(\.path).contains(staticLibSidecar))
                    #expect(task.commandLineAsStrings.contains(where: { $0.hasPrefix("--target-triple=") }))
                }
                results.checkNoDiagnostics()
            }
        }

        // Negative case: StaticLib has INVOKE_SSAF=NO. Test must not reference any StaticLib
        // sidecar, must not pin --target-triple (nothing triggered it), and must not error.
        do {
            let tester = try TaskConstructionTester(core, getTestProject(libraryInvokesSSAF: "NO"))
            await tester.checkBuild(runDestination: .host) { results in
                results.checkNoTask(.matchTargetName("StaticLib"), .matchRuleType("LinkEntity"))
                results.checkTask(.matchTargetName("Test"), .matchRuleType("LinkEntity")) { task in
                    #expect(!task.inputs.map(\.path).contains(where: { $0.str.hasSuffix(".ssaf-staticlib.json") }))
                    #expect(!task.commandLineAsStrings.contains(where: { $0.hasPrefix("--target-triple=") }))
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// The multi-arch variant of invokeSsafStaticLibraryDependency: a static library dependency's
    /// per-arch StaticLibrary bundles must be merged (via `multi-arch create`) into one canonical
    /// MultiArchStaticLibrary, and a dependent target's per-arch flat link steps must each reference
    /// that canonical bundle -- never a per-arch, stranded PER_SLICE_OBJECT_FILE_DIR path.
    @Test(.requireSDKs(.macOS), .requireClangFeatures(.invokeSsaf))
    func invokeSsafStaticLibraryDependencyMultiArch() async throws {
        let libtoolPath = try await self.libtoolPath
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("LibFile.c"),
                    TestFile("File1.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "INVOKE_SSAF": "YES",
                        "EXTRACT_SUMMARIES": "CallGraph",
                        "ARCHS": "x86_64 arm64",
                        "MACOSX_DEPLOYMENT_TARGET": "12.0",
                        "LIBTOOL": libtoolPath.str,
                    ]),
            ],
            targets: [
                // "Test" must be declared first: TaskConstructionTester.checkBuild() with no explicit
                // targetName builds only project.targets[0] (plus its dependencies transitively), so
                // the target actually under test needs to be first, not its dependency.
                TestStandardTarget(
                    "Test",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["File1.c"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("StaticLib"))]),
                    ],
                    dependencies: ["StaticLib"]
                ),
                TestStandardTarget(
                    "StaticLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["LibFile.c"]),
                    ]
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        await tester.checkBuild(runDestination: .anyMac) { results in
            // StaticLib: 2 per-arch flat links + 2 per-arch static-library-create bundles, plus a
            // multi-arch merge for each family (linked-summaries and static-library bundles).
            var staticLibCanonicalSidecar: Path? = nil
            results.checkTasks(.matchTargetName("StaticLib"), .matchRuleType("LinkEntity")) { tasks in
                let allTasks = Array(tasks)
                #expect(allTasks.count == 6)

                let staticLibraryCreateTasks = allTasks.filter { $0.commandLineAsStrings.contains("static-library") }
                #expect(staticLibraryCreateTasks.count == 2)

                let mergeTasks = allTasks.filter { $0.commandLineAsStrings.contains("multi-arch") }
                #expect(mergeTasks.count == 2)

                // The multi-arch merge whose inputs are the per-arch static-library bundles (not the
                // per-arch flat linked-summaries) produces the canonical .ssaf-staticlib.json that a
                // dependent target should reference. (Inputs may also include a benign extra
                // zero-length path contributed by CommandLineToolSpec's generic build-option-derived
                // additionalInputDependencies mechanism, so match by "contains" rather than "allSatisfy".)
                let staticLibraryMergeTasks = mergeTasks.filter { task in
                    task.inputs.contains { $0.path.str.hasSuffix(".ssaf-staticlib.json") }
                }
                #expect(staticLibraryMergeTasks.count == 1)
                staticLibCanonicalSidecar = staticLibraryMergeTasks.first?.outputs.map(\.path).first(where: { $0.str.hasSuffix(".ssaf-staticlib.json") })
                if let staticLibCanonicalSidecar {
                    // The canonical bundle sits next to the target's own product, not under the
                    // per-arch "Binary" subdirectory ssafArtifactPath uses for PER_SLICE_OBJECT_FILE_DIR.
                    #expect(!staticLibCanonicalSidecar.str.contains("/Binary/"))
                }
            }

            // Test: one flat-link LinkEntity task per arch, each referencing the *same* canonical
            // StaticLib bundle and pinning --target-triple for its own arch.
            results.checkTasks(.matchTargetName("Test"), .matchRuleType("LinkEntity")) { tasks in
                let allTasks = Array(tasks)
                let flatLinkTasks = allTasks.filter { !$0.commandLineAsStrings.contains("multi-arch") }
                #expect(flatLinkTasks.count == 2)

                guard let staticLibCanonicalSidecar else {
                    Issue.record("Expected StaticLib to produce a canonical .ssaf-staticlib.json bundle")
                    return
                }
                var seenTriples = Set<String>()
                for task in flatLinkTasks {
                    #expect(task.inputs.map(\.path).contains(staticLibCanonicalSidecar))
                    let tripleArgs = task.commandLineAsStrings.filter { $0.hasPrefix("--target-triple=") }
                    #expect(tripleArgs.count == 1)
                    if let tripleArg = tripleArgs.first {
                        seenTriples.insert(tripleArg)
                    }
                }
                // Each arch's flat link must pin its own distinct triple.
                #expect(seenTriples.count == 2)
            }

            results.checkNoDiagnostics()
        }
    }
}
