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
import SWBMacro
import SWBTestSupport
import SWBUtil
import SWBTaskConstruction

@Suite
fileprivate struct ClangModulesTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func onlySupportedLanguagesEnableModules() async throws {
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
                        TestFile("c.cpp"),
                        TestFile("d.mm"),
                        TestFile("e.s"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "NO",
                            "CLANG_ENABLE_MODULES": "YES",
                            "CC": clangCompilerPath.str
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c", "b.m", "c.cpp", "d.mm", "e.s"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("a.c"))) { compileTask in
                    compileTask.checkCommandLineContains(["-fmodules"])
                }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("b.m"))) { compileTask in
                    compileTask.checkCommandLineContains(["-fmodules"])
                }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("c.cpp"))) { compileTask in
                    compileTask.checkCommandLineContains(["-fmodules"])
                }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("d.mm"))) { compileTask in
                    compileTask.checkCommandLineContains(["-fmodules"])
                }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("e.s"))) { compileTask in
                    compileTask.checkCommandLineDoesNotContain("-fmodules")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), arguments: [false, true])
    func cxxExplicitModulesOptIn(allowCxx: Bool) async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.m"),
                        TestFile("c.cpp"),
                        TestFile("d.mm"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": self.libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "NO",
                            "CLANG_ENABLE_MODULES": "YES",
                            "CLANG_ENABLE_EXPLICIT_MODULES": "YES",
                            "CC": clangCompilerPath.str,
                            "OTHER_CPLUSPLUSFLAGS": allowCxx ? "-fcxx-modules" : ""
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c", "b.m", "c.cpp", "d.mm"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                // C and ObjC always scan once explicit modules is enabled.
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("a.o"))
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("b.o"))

                if allowCxx {
                    results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("c.o"))
                    results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("d.o"))
                } else {
                    results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("c.o"))
                    results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("d.o"))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    /// Testing the EBM block list when caching is off and on.
    @Test(.requireSDKs(.macOS), arguments: [false, true])
    func clangExplicitModulesBlocklist(compileCache: Bool) async throws {
        let libtoolPath = try await self.libtoolPath
        let clangPath = try await self.clangCompilerPath
        try await withTemporaryDirectory { tmpDir in
            let blocklistsDir = tmpDir.join("blocklists")
            try localFS.createDirectory(blocklistsDir, recursive: true)
            try await localFS.writeFileContents(blocklistsDir.join("clang-explicit-modules.json")) { stream in
                stream <<<
                """
                { "KnownFailures": ["aProject"] }
                """
            }

            var buildSettings:[String: String] = [
                "LIBTOOL": libtoolPath.str,
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_USE_RESPONSE_FILE": "NO",
                "CLANG_ENABLE_MODULES": "YES",
                "CLANG_ENABLE_EXPLICIT_MODULES": "YES",
                "OTHER_CPLUSPLUSFLAGS": "-fcxx-modules",
                "BLOCKLISTS_PATH": blocklistsDir.str,
                "CC": clangPath.str,
            ]

            if compileCache {
                buildSettings["CLANG_ENABLE_COMPILE_CACHE"] = "YES"
                buildSettings["COMPILATION_CACHE_CAS_PATH"] = tmpDir.join("CompilationCache").str
            }

            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.m"),
                        TestFile("c.cpp"),
                        TestFile("d.mm"),
                    ]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: buildSettings)],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["a.c", "b.m", "c.cpp", "d.mm"]),
                        ]
                    )
                ])

            // Construct a custom core to test project identity based matching.
            let core = try await Self.makeCore(registerExtraPlugins: { pluginManager in
                struct TestSettingsBuilderExtension: SettingsBuilderExtension {
                    func matchesAnyProjectIdentities(scope: MacroEvaluationScope, projectIdentities: Set<String>) -> Bool {
                        projectIdentities.contains(scope.evaluate(BuiltinMacros.PROJECT_NAME))
                    }
                }
                pluginManager.register(TestSettingsBuilderExtension(), type: SettingsBuilderExtensionPoint.self)
            })

            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("a.o"))
                results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("b.o"))
                results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("c.o"))
                results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("d.o"))

                // Check that modules are still on.
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("a.c"))) { task in
                    task.checkCommandLineContains(["-fmodules"])
                    // Caching requires explicit modules, so it has to be off.
                    task.checkCommandLineDoesNotContain("-fcas-backend")
                }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("c.cpp"))) { task in
                    task.checkCommandLineContains(["-fmodules"])
                    task.checkCommandLineContains(["-fcxx-modules"])
                    // Caching requires explicit modules, so it has to be off.
                    task.checkCommandLineDoesNotContain("-fcas-backend")
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// Testing differet configurations that controls C++ explicit modules.
    struct CxxModulesFlagCase: Sendable, CustomTestStringConvertible {
        let name: String
        let settings: [String: String]
        let perFileArgs: [String]?
        let expectScan: Bool
        var testDescription: String { name }
    }

    @Test(.requireSDKs(.macOS), arguments: [
        CxxModulesFlagCase(name: "OTHER_CFLAGS via OTHER_CPLUSPLUSFLAGS default",
                           settings: ["OTHER_CFLAGS": "-fcxx-modules"], perFileArgs: nil, expectScan: true),
        CxxModulesFlagCase(name: "last flag wins, off",
                           settings: ["OTHER_CPLUSPLUSFLAGS": "-fcxx-modules -fno-cxx-modules"], perFileArgs: nil, expectScan: false),
        CxxModulesFlagCase(name: "last flag wins, on",
                           settings: ["OTHER_CPLUSPLUSFLAGS": "-fno-cxx-modules -fcxx-modules"], perFileArgs: nil, expectScan: true),
        CxxModulesFlagCase(name: "per-file overrides target",
                           settings: ["OTHER_CPLUSPLUSFLAGS": "-fno-cxx-modules"], perFileArgs: ["-fcxx-modules"], expectScan: true),
        CxxModulesFlagCase(name: "CLANG_DISABLE_CXX_MODULES=NO",
                           settings: ["CLANG_DISABLE_CXX_MODULES": "NO"], perFileArgs: nil, expectScan: true),
    ])
    func cxxHeaderModulesFlagResolution(_ testCase: CxxModulesFlagCase) async throws {
        let libtoolPath = try await self.libtoolPath
        let clangPath = try await self.clangCompilerPath
        try await withTemporaryDirectory { tmpDir in
            var buildSettings: [String: String] = [
                "LIBTOOL": libtoolPath.str,
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "CLANG_USE_RESPONSE_FILE": "NO",
                "CLANG_ENABLE_MODULES": "YES",
                "CLANG_ENABLE_EXPLICIT_MODULES": "YES",
                "CC": clangPath.str,
            ]
            buildSettings.merge(testCase.settings) { _, new in new }

            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup("SomeFiles", children: [TestFile("c.cpp")]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: buildSettings)],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("c.cpp", additionalArgs: testCase.perFileArgs)]),
                        ])
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                if testCase.expectScan {
                    results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("c.o"))
                } else {
                    results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("c.o"))
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cxxHeaderModulesPerFileGranularity() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup("SomeFiles", children: [
                    TestFile("a.c"), TestFile("c.cpp"), TestFile("d.mm"),
                ]),
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                    "LIBTOOL": self.libtoolPath.str,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                    "CLANG_ENABLE_MODULES": "YES",
                    "CLANG_ENABLE_EXPLICIT_MODULES": "YES",
                    "CC": clangCompilerPath.str,
                ])],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "a.c",
                                TestBuildFile("c.cpp", additionalArgs: ["-fcxx-modules"]),
                                "d.mm",
                            ]),
                        ])
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("a.o"))
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("c.o"))
                results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("d.o"))
                results.checkNoDiagnostics()
            }
        }
    }


    /// With caching enabled, C++/ObjC++ reach explicit modules via the caching path even when
    /// `CLANG_ENABLE_EXPLICIT_MODULES` is NO. The "Compile caching is not supported
    /// with implicit modules" warning should not fire for these sources.
    @Test(.requireSDKs(.macOS))
    func cxxCachingUnaffectedWhenExplicitModulesDisabled() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("c.cpp"),
                        TestFile("d.mm"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": self.libtoolPath.str,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_USE_RESPONSE_FILE": "NO",
                            "CLANG_ENABLE_MODULES": "YES",
                            "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
                            "CLANG_ENABLE_COMPILE_CACHE": "YES",
                            "CC": clangCompilerPath.str,
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Test",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["c.cpp", "d.mm"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                // C++/ObjC++ still scan when caching is on even when CLANG_ENABLE_EXPLICIT_MODULES is NO.
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("c.o"))
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("d.o"))
                // And no "Compile caching is not supported with implicit modules" warning.
                results.checkNoDiagnostics()
            }
        }
    }
}

