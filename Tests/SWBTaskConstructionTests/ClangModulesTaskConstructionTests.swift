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
}
