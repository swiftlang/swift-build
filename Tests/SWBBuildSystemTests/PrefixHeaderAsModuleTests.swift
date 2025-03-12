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
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import SWBProtocol

@Suite(.requireDependencyScanner)
fileprivate struct PrefixHeaderAsModuleTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func precompiledHeaderAsModule() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                                TestFile("pch.h"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                "GCC_PREFIX_HEADER": "pch.h",
                                "CLANG_IMPORT_PREFIX_HEADER_AS_MODULE": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/pch.h")) { stream in
                stream <<<
                """
                typedef int PCH_int;
                #define PCH_one 1
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                PCH_int foo(void) {
                  return PCH_one;
                }
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchRuleType("ScanDependencies")) { scanTask in
                    try results.checkTaskFollows(scanTask, .matchRulePattern(["WriteAuxiliaryFile", .and(.prefix("\(tmpDirPath.str)/Test/aProject/build/SharedPrecompiledHeaders/SharedPrefixModuleMaps/pch.h-"), .suffix(".modulemap"))]))
                }

                results.checkTask(.matchRuleType("PrecompileModule")) { _ in }
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func precompiledHeaderAsModuleImplicit() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                                TestFile("pch.h"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "NO",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                "GCC_PREFIX_HEADER": "pch.h",
                                "CLANG_IMPORT_PREFIX_HEADER_AS_MODULE": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/pch.h")) { stream in
                stream <<<
                """
                typedef int PCH_int;
                #define PCH_one 1
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                PCH_int foo(void) {
                  return PCH_one;
                }
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkNoTask(.matchRuleType("ProcessPCH"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func precompiledHeaderAsModuleCxx() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.cpp"),
                                TestFile("pch.h"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "OTHER_CFLAGS": "-fmodules -fcxx-modules",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                "GCC_PREFIX_HEADER": "pch.h",
                                "CLANG_IMPORT_PREFIX_HEADER_AS_MODULE": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.cpp"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/pch.h")) { stream in
                stream <<<
                """
                typedef int PCH_int;
                #define PCH_one 1
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.cpp")) { stream in
                stream <<<
                """
                PCH_int foo(void) {
                  return PCH_one;
                }
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("CompileC")) { _ in }
                results.checkTask(.matchRuleType("ProcessPCH++")) { _ in }
                results.checkNoDiagnostics()
            }
        }
    }
}
