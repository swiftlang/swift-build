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
import SWBUtil

import SWBTaskConstruction
import SWBProtocol

@Suite
fileprivate struct ClangStaticAnalyzerTests: CoreBasedTests {
    /// Check that Build & Analyze works.
    @Test(.requireSDKs(.host))
    func buildAndAnalyze() async throws {
        let testProject = TestProject(
            "aProject",
            defaultConfigurationName: "Release",
            groupTree: TestGroup("Foo", children: [
                TestFile("foo.c"),
                TestFile("bar.s"),
            ]),
            targets: [TestStandardTarget("Lib", type: .dynamicLibrary,
                                         buildPhases: [
                                            TestSourcesBuildPhase([
                                                "foo.c",
                                                "bar.s", // should not get analyzed
                                            ])])])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Test basics.
        // CLANG_STATIC_ANALYZER_MODE defaults to "shallow".
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES", "CLANG_USE_RESPONSE_FILE": "NO"]), runDestination: .host) { results in
            results.checkTarget("Lib") { target in
                let effectivePlatformName = results.builtProductsDirSuffix(target)
                let arch = results.runDestinationTargetArchitecture
                results.checkNoTask(.matchTarget(target), .matchRule(["AnalyzeShallow", "\(SRCROOT)/bar.s"]))

                results.checkTask(.matchTarget(target), .matchRuleType("AnalyzeShallow")) { task in
                    task.checkRuleInfo(["AnalyzeShallow", Path(SRCROOT).join("foo.c").str, "normal", arch])
                    task.checkCommandLineContains(["--analyze"])
                    task.checkCommandLineContains(["-Xclang", "-analyzer-config", "-Xclang", "mode=shallow"])
                    task.checkCommandLineContains(["-MF", Path(SRCROOT).join("build/aProject.build/Debug\(effectivePlatformName)/Lib.build/StaticAnalyzer/aProject/Lib/normal/\(arch)/foo.d").str])
                    task.checkCommandLineContains(["-o", Path(SRCROOT).join("build/aProject.build/Debug\(effectivePlatformName)/Lib.build/StaticAnalyzer/aProject/Lib/normal/\(arch)/foo.plist").str])
                    #expect(!task.commandLine.contains("--serialize-diagnostics"))
                    task.checkOutputs([.path(Path(SRCROOT).join("build/aProject.build/Debug\(effectivePlatformName)/Lib.build/StaticAnalyzer/aProject/Lib/normal/\(arch)/foo.plist").str)])
                }
            }
            results.checkNoDiagnostics()
        }
        // CLANG_STATIC_ANALYZER_MODE = "deep" and "" are synonymous.
        for mode in ["deep", ""] {
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES", "CLANG_STATIC_ANALYZER_MODE": mode]), runDestination: .host) { results in
                results.checkTarget("Lib") { target in
                    let effectivePlatformName = results.builtProductsDirSuffix(target)
                    let arch = results.runDestinationTargetArchitecture
                    results.checkNoTask(.matchTarget(target), .matchRule(["Analyze", "\(SRCROOT)/bar.s"]))

                    results.checkTask(.matchTarget(target), .matchRuleType("Analyze")) { task in
                        task.checkRuleInfo(["Analyze", Path(SRCROOT).join("foo.c").str, "normal", arch])
                        task.checkCommandLineContains(["--analyze"])
                        task.checkCommandLineNoMatch([.prefix("mode=")])
                        task.checkCommandLineContains(["-MF", Path(SRCROOT).join("build/aProject.build/Debug\(effectivePlatformName)/Lib.build/StaticAnalyzer/aProject/Lib/normal/\(arch)/foo.d").str])
                        task.checkCommandLineContains(["-o", Path(SRCROOT).join("build/aProject.build/Debug\(effectivePlatformName)/Lib.build/StaticAnalyzer/aProject/Lib/normal/\(arch)/foo.plist").str])
                        #expect(!task.commandLine.contains("--serialize-diagnostics"))
                        task.checkOutputs([.path(Path(SRCROOT).join("build/aProject.build/Debug\(effectivePlatformName)/Lib.build/StaticAnalyzer/aProject/Lib/normal/\(arch)/foo.plist").str)])
                    }
                }
                results.checkNoDiagnostics()
            }
        }
        let runDestination: RunDestinationInfo = .host
        let architectures: [String] = switch runDestination {
        case .macOS:
            ["armv7", "x86_64"]
        case .linux, .windows:
            ["aarch64, x86_64"]
        default:
            [""]
        }

        if architectures.count == 2 {
            // Test that analyzing multiple archs produces only one analyze rule.
            let overrides = [
                "ARCHS": architectures.joined(separator: " "),
                "ONLY_ACTIVE_ARCH": "NO",
                "RUN_CLANG_STATIC_ANALYZER": "YES",
                "CLANG_STATIC_ANALYZER_MODE": "deep",
                "VALID_ARCHS": architectures.joined(separator: " ")
            ]
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: overrides), runDestination: .host) { results in
                results.checkTarget("Lib") { target in
                    results.checkNoTask(.matchTarget(target), .matchRule(["Analyze", Path(SRCROOT).join("bar.s").str]))

                    results.checkTask(.matchTarget(target), .matchRuleType("Analyze")) { task in
                        task.checkRuleInfo(["Analyze", Path(SRCROOT).join("foo.c").str, "normal", architectures[1]])
                        // We should be only analyzing 64 bit arch.
                        task.checkOutputs(contain: [.pathPattern(.suffix(Path(architectures[1]).join("foo.plist").str))])
                    }

                    // For each file, we should have two compile tasks, one for each arch.
                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem(Path(SRCROOT).join("foo.c").str)) { tasks in
                        #expect(tasks.count == 2)
                    }
                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem(Path(SRCROOT).join("bar.s").str)) { tasks in
                        #expect(tasks.count == 2)
                    }
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Check that a custom analyzer binary set via CLANG_ANALYZER_EXEC works.
    @Test(.requireSDKs(.macOS))
    func buildAndAnalyzeCustomAnalyzer() async throws {
        let testProject = TestProject(
            "aProject",
            defaultConfigurationName: "Release",
            groupTree: TestGroup("Foo", children: [
                TestFile("foo.c"),
            ]),
            targets: [TestStandardTarget("Lib", type: .dynamicLibrary,
                                         buildPhases: [
                                            TestSourcesBuildPhase([
                                                "foo.c",
                                            ])])])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])

        try await TaskConstructionTester(getCore(), testWorkspace).checkBuild(BuildParameters(configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES", "CLANG_ANALYZER_EXEC": "clang-custom"]), runDestination: .macOS) { results in
            results.checkTarget("Lib") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("AnalyzeShallow")) { task in
                    task.checkCommandLineContains(["clang-custom"])
                }
            }
            results.checkNoDiagnostics()
        }
    }

    /// Check that skipping the static analyzer by setting SKIP_CLANG_STATIC_ANALYZER in a target works.
    @Test(.requireSDKs(.macOS))
    func skippingStaticAnalyzer() async throws {
        let testProject = TestProject(
            "aProject",
            defaultConfigurationName: "Release",
            groupTree: TestGroup("Foo", children: [
                TestFile("foo.c"),
            ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget("AnalyzedLib",
                                   type: .dynamicLibrary,
                                   buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ])
                                   ],
                                   dependencies: ["UnanalyzedLib"]),
                TestStandardTarget("UnanalyzedLib",
                                   type: .dynamicLibrary,
                                   buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "SKIP_CLANG_STATIC_ANALYZER": "YES",
                                    ])
                                   ],
                                   buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ])
                                   ])
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])

        try await TaskConstructionTester(getCore(), testWorkspace).checkBuild(BuildParameters(configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), runDestination: .macOS) { results in
            results.checkTarget("AnalyzedLib") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("AnalyzeShallow")) { _ in }
            }
            results.checkTarget("UnanalyzedLib") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("AnalyzeShallow"))
            }
            results.checkNoDiagnostics()
        }
    }
}
