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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct ClangResponseFileTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func basics() async throws {
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.c"),
                        TestFile("c.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "YES",
                            "CC": clangCompilerPath.str
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c", "b.c", "c.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            try await tester.checkBuild(runDestination: .host) { results in
                try results.checkWriteAuxiliaryFileTask(.matchRuleItemPattern(.suffix("-common-args.resp"))) { task, contents in
                    let responseFilePath = try #require(task.outputs.only)

                    // The command arguments in the response file vary vastly between different platforms, so just check for some basics present in the content.
                    let contentAsString = contents.asString
                    #expect(contentAsString.contains("-target "))
                    #expect(contentAsString.contains("Test-generated-files.hmap"))
                    #expect(contentAsString.contains("Test-own-target-headers.hmap"))
                    #expect(contentAsString.contains("Test-all-target-headers.hmap"))

                    for name in ["a.c", "b.c", "c.c"] {
                        results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix(name))) { compileTask in
                            results.checkTaskFollows(compileTask, antecedent: task)
                            compileTask.checkCommandLineContains(["@\(responseFilePath.path.str)"])
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func disabledByCompilerWrapper() async throws {
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.c"),
                        TestFile("c.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CC": "\(tmpDir.join("efi-clang").str)",
                            "CLANG_USE_RESPONSE_FILE": "YES",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c", "b.c", "c.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .host) { results in
                results.checkNoTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix(".resp")]))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func responseFileExclusions() async throws {
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.c"),
                        TestFile("c.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "YES",
                            "CLANG_COLOR_DIAGNOSTICS": "YES",
                            "CLANG_ENABLE_MODULES": "YES",
                            "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
                            "CLANG_MODULES_DISABLE_PRIVATE_WARNING": "YES",
                            "CC": clangCompilerPath.str
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c", "b.c", "c.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .host) { results in
                results.checkWriteAuxiliaryFileTask(.matchRuleItemPattern(.suffix("-common-args.resp"))) { task, contents in
                    let stringContents = contents.asString
                    #expect(stringContents.contains("-target"))
                    let blocksFlag = switch runDestination {
                        case .macOS:
                            "-fasm-blocks"
                        case .linux:
                            "-fblocks"
                        default:
                            " "
                    }
                    #expect(stringContents.contains(blocksFlag))
                    #expect(!stringContents.contains("-MMD"))
                    #expect(!stringContents.contains("-fcolor-diagnostics"))
                    #expect(!stringContents.contains("-Wno-private-module"))
                    for name in ["a", "b", "c"] {
                        results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix(name + ".c"))) { compileTask in
                            compileTask.checkCommandLineMatches(["-MMD", "-MT", "dependencies", "-MF", .suffix(name + ".d")])
                            compileTask.checkCommandLineContains(["-fcolor-diagnostics"])
                            compileTask.checkCommandLineContains(["-Wno-private-module"])
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func perLanguageResponseFiles() async throws {
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.m"),
                        TestFile("c.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "YES",
                            "CC": clangCompilerPath.str
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c", "b.m", "c.m"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .host) { results in
                var aResponseFile: Path? = nil
                var bResponseFile: Path? = nil
                var cResponseFile: Path? = nil
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("a.c"))) { compileTask in
                    aResponseFile = compileTask.inputs.map(\.path).filter { $0.fileExtension == "resp" }.only
                }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("b.m"))) { compileTask in
                    bResponseFile = compileTask.inputs.map(\.path).filter { $0.fileExtension == "resp" }.only
                }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("c.m"))) { compileTask in
                    cResponseFile = compileTask.inputs.map(\.path).filter { $0.fileExtension == "resp" }.only
                }
                guard let aResponseFile, let bResponseFile, let cResponseFile else {
                    Issue.record("Did not find expected response file inputs")
                    return
                }
                #expect(bResponseFile == cResponseFile)
                #expect(aResponseFile != bResponseFile)
            }
        }
    }

    @Test(.requireSDKs(.host))
    func perSpecResponseFiles() async throws {
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "YES",
                            "RUN_CLANG_STATIC_ANALYZER": "YES",
                            "CC": clangCompilerPath.str
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .host) { results in
                var compileResponseFile: Path? = nil
                var analyzeResponseFile: Path? = nil
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("a.c"))) { compileTask in
                    compileResponseFile = compileTask.inputs.map(\.path).filter { $0.fileExtension == "resp" }.only
                }
                results.checkTask(.matchRuleType("AnalyzeShallow"), .matchRuleItemPattern(.suffix("a.c"))) { analyzeTask in
                    analyzeResponseFile = analyzeTask.inputs.map(\.path).filter { $0.fileExtension == "resp" }.only
                }

                guard let compileResponseFile, let analyzeResponseFile else {
                    Issue.record("Did not find expected response file inputs")
                    return
                }
                #expect(compileResponseFile != analyzeResponseFile)
            }
        }
    }

    @Test(.requireSDKs(.host))
    func responseFilePassthroughArgs() async throws {
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "YES",
                            "CLANG_COLOR_DIAGNOSTICS": "YES",
                            "CLANG_ENABLE_MODULES": "YES",
                            "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
                            "CLANG_MODULES_DISABLE_PRIVATE_WARNING": "YES",
                            "CC": clangCompilerPath.str,
                            "OTHER_CFLAGS": "-Xclang -Wno-shorten-64-to-32" // matches a precompiled-header neutral pattern, but uses -Xclang
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .host) { results in
                results.checkWriteAuxiliaryFileTask(.matchRuleItemPattern(.suffix("-common-args.resp"))) { task, contents in
                    let stringContents = contents.asString
                    #expect(stringContents.contains("-Xclang -Wno-shorten-64-to-32"))
                    results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("a.c"))) { compileTask in
                        compileTask.checkCommandLineDoesNotContain("-Xclang")
                    }
                }
            }
        }
    }

}
