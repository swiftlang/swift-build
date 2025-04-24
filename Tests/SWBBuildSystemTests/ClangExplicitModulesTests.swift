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

import class Foundation.FileManager

import Testing

import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import SWBProtocol

@Suite(.requireDependencyScanner, .requireXcode16())
fileprivate struct ClangExplicitModulesTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func explicitModulesBasic() async throws {
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
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }

                // Make sure scanning happens before compilation...
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                // ... and make sure pcms also get precompiled before compilation.
                results.checkTasks(.matchRuleType("PrecompileModule")) { pcmTasks in
                    for pcmTask in pcmTasks {
                        results.check(event: .taskHadEvent(pcmTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))
                    }
                }

                results.checkNoDiagnostics()
            }

            // Modify the source file to trigger a new scan.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 2;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // the test stops at point of failure, so no additional failures are observed. behaves correctly
                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }

                // None of the pcm inputs changed, so we should not be precompiling pcms again.
                results.checkNoTask(.matchRuleType("PrecompileModule"))

                // Make sure scanning happens before compilation.
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesLibclangOpenFailure() async throws {
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
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": Path.null.str,
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkError(.and(.contains("error scanning dependencies for source"), .contains("could not load \(Path.null.str)")))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesMultipleSources() async throws {
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
                                TestFile("other.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c", "other.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int otherthing = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                // There should only be 2 scanning actions.
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                let pcmRuleInfos = results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in tasks.map(\.ruleInfo) }

                // Make sure only one instance of the PrecompileModule was executed for each module.
                #expect(pcmRuleInfos.count == Set(pcmRuleInfos).count)

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesMixedSources() async throws {
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
                                TestFile("other.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c", "other.m"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/other.m")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                int otherthing = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                // There should only be 2 scanning actions.
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                let pcmRuleInfos = results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in tasks.map(\.ruleInfo) }

                // Make sure only one instance of the PrecompileModule was executed for each module.
                #expect(pcmRuleInfos.count == Set(pcmRuleInfos).count)

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesWithPrecompiledHeader() async throws {
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
                                TestFile("module.modulemap"),
                                TestFile("mod.h"),
                                TestFile("pch.h"),
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["GCC_PREFIX_HEADER": "pch.h"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
                """
                module Mod { header "mod.h" }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod.h")) { stream in
                stream <<<
                """
                typedef int mod_int;
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/pch.h")) { stream in
                stream <<<
                """
                #include "mod.h"
                typedef mod_int pch_int;
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include "mod.h"
                mod_int some = 1;
                pch_int thing = 2;
                """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                // There should be 2 scanning actions - one for the precompiled header, one for the translation unit.
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                results.checkTask(.matchRuleType("ProcessPCH")) { _ in }

                let pcmRuleInfos = results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in tasks.map(\.ruleInfo) }

                // Make sure only one instance of the PrecompileModule was executed for each module.
                #expect(pcmRuleInfos.count == Set(pcmRuleInfos).count)

                results.checkTask(.matchRuleType("CompileC")) { _ in }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesEnvironment() async throws {
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
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "OTHER_CFLAGS": "-Wmain -Werror",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                int main(int argc) {}
                """
            }

            // FIXME: These two lines shouldn't be necessary. clang directly recognizes the same of this environment variable (coincidentally the same as our build setting). llbuild's shell tool has an `inherit-env` property which is true by default, and causes the _process_ environment of the build service to be propagated to build tasks like clang. Instead we should set `inherit-env` to false and merge `processEnvironment` from UserInfo into the task's environment, so that it is overridable from tests.
            try POSIX.setenv("GCC_TREAT_WARNINGS_AS_ERRORS", "NO", 1)
            defer { try? POSIX.unsetenv("GCC_TREAT_WARNINGS_AS_ERRORS") }

            tester.userInfo = UserInfo(user: "user", group: "group", uid: 1337, gid: 42, home: tmpDirPath.join("home"), processEnvironment: [:], buildSystemEnvironment: [:])
            tester.userInfo = tester.userInfo.withAdditionalEnvironment(environment: ["GCC_TREAT_WARNINGS_AS_ERRORS": "NO"])
            try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that -Werror was overwritten by GCC_TREAT_WARNINGS_AS_ERRORS=NO.
                results.checkNoErrors()
                results.checkWarning(.contains("only one parameter on 'main'"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesWorkingDirectory() async throws {
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
                                TestGroup(
                                    "Includes",
                                    children: [
                                        TestFile("header.h")
                                    ]),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "SYSTEM_HEADER_SEARCH_PATHS": "Includes",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <header.h>
                int main() {}
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Includes/header.h")) { stream in
                stream <<<
                """
                typedef int header_int;
                """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                // Check that the "Includes" header search path got picked up due to CompileC being executed in the project source directory.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesWithFramework() async throws {

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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <Framework/Framework.h>

                void test() {
                    NSLog(@"%@", [[Shared alloc] init]);
                }

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                // There should only be 2 scanning actions.
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                let pcmRuleInfos = results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in tasks.map(\.ruleInfo) }

                // Make sure only one instance of the PrecompileModule was executed for each module.
                #expect(pcmRuleInfos.count == Set(pcmRuleInfos).count)

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesDriverExpandsToMultipleCC1s() async throws {
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
                                TestFile("mod.h"),
                                TestFile("module.modulemap"),
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                // This makes the Clang driver invocation expand into multiple -cc1 invocations.
                                "OTHER_CFLAGS": "-save-temps=obj",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
                """
                module mod { header "mod.h" }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod.h")) { stream in
                stream <<<
                """
                typedef int int_mod;
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include "mod.h"
                int_mod x = 42;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("ScanDependencies")) { _ in }
                results.checkTask(.matchRuleType("PrecompileModule")) { _ in }
                var outputs = results.checkTask(.matchRuleType("CompileC")) { task in
                    task.outputPaths
                } ?? []

                results.checkNoDiagnostics()

                guard let obj = outputs.only else {
                    Issue.record("expected 1 .o output, got \(outputs)")
                    return
                }

                // From -save-times=obj
                outputs.append(Path(obj.withoutSuffix + ".i"))
                outputs.append(Path(obj.withoutSuffix + ".s"))

                for path in outputs {
                    #expect(FileManager.default.fileExists(atPath: path.str), "missing output \(path)")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesWithLauncher() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let launcherTest = { (allowLauncher: Bool) async throws -> BuildOperationTester in
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                children: [
                                    TestFile("mod.h"),
                                    TestFile("module.modulemap"),
                                    TestFile("file.c"),
                                ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "C_COMPILER_LAUNCHER": "/usr/bin/time",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                    "CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER": allowLauncher ? "YES" : "NO",
                                ])],
                            targets: [
                                TestStandardTarget(
                                    "Library",
                                    type: .staticLibrary,
                                    buildPhases: [
                                        TestSourcesBuildPhase(["file.c"]),
                                    ]),
                            ])])

                let tester = try await BuildOperationTester(self.getCore(), testWorkspace, simulated: false)
                tester.userPreferences = UserPreferences.defaultForTesting.with(enableDebugActivityLogs: true)

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                    stream <<<
                    """
                    module mod { header "mod.h" }
                    """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod.h")) { stream in
                    stream <<<
                    """
                    typedef int int_mod;
                    """
                }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<<
                    """
                    #include "mod.h"
                    int_mod x = 42;
                    """
                }

                return tester
            }

            let clangCompilerPath = try await self.clangCompilerPath

            // CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER = YES
            try await launcherTest(true).checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("ScanDependencies")) { _ in }

                results.checkTask(.matchRuleType("PrecompileModule")) { pcmTask in
                    results.checkTaskOutput(pcmTask) { pcmOutput in
                        XCTAssertMatch(pcmOutput.stringValue, .prefix(UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .argumentsOnly).encode(["/usr/bin/time", clangCompilerPath.str, "-cc1"])))
                    }
                }

                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    results.checkTaskOutput(compileTask) { compileOutput in
                        // The post-scan command-line is part of the output, so we can check for the launcher directly.
                        XCTAssertMatch(compileOutput.stringValue, .prefix(UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .argumentsOnly).encode(["/usr/bin/time", clangCompilerPath.str])))
                    }
                }

                results.checkNoDiagnostics()
            }

            // CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER = NO
            try await launcherTest(false).checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"))
                results.checkNoTask(.matchRuleType("PrecompileModule"))
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    results.checkTaskOutput(compileTask) { compileOutput in
                        // The command-line is not in the output, but we can check for the time output.
                        XCTAssertMatch(compileOutput.stringValue, .and(.contains("real"), .contains("user")))
                    }
                }
                results.checkNoErrors()
                results.checkRemark(.prefix("Explicit modules is not supported with C_COMPILER_LAUNCHER"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func precompileDiagnostics() async throws {

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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <Framework/Framework.h>

                void test() {
                    NSLog(@"%@", [[Shared alloc] init]);
                }

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>

                int foo(void) {
                    return
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkError(.contains("expected expression"))
                results.checkError(.prefix("Command PrecompileModule failed."))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func analyzerRequestedPrecompilesDoNotAttemptSerializedDiagnosticsParsing() async throws {

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
                                TestFile("file.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"])
                                ]
                            )
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                @import Foundation;

                void test() {
                    int x;
                    NSLog(@"%d", x);
                }
                """
            }

            try await tester.checkBuild(parameters: BuildParameters(action: .analyze, configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), runDestination: .macOS) { results in
                // We should not see any warnings about missing serialized diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireStructuredDiagnostics)
    func scannerDiagnostics() async throws {
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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                ]
                            )
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <DoesNotExist/DoesNotExist.h>

                void test() {
                    NSLog(@"%@", [[Shared alloc] init]);
                }
                """
            }

            // The build should produce structured diagnostics.
            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkError(.contains("[Lexical or Preprocessor Issue] 'DoesNotExist/DoesNotExist.h' file not found (for task: [\"ScanDependencies\""))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func withClangWrapperScript() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        try await withTemporaryDirectory { tmpDirPath in
            let efiClang = tmpDirPath.join("efi-clang")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("mod.h"),
                                TestFile("module.modulemap"),
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CC": "\(efiClang.str)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(self.getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(efiClang) { stream in
                stream <<< """
                #!/usr/bin/env sh
                \(clangCompilerPath.str) -v $@
                """
            }
            try tester.fs.setFilePermissions(efiClang, permissions: 0o755)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
                """
                module mod { header "mod.h" }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod.h")) { stream in
                stream <<<
                """
                typedef int int_mod;
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include "mod.h"
                int_mod x = 42;
                """
            }


            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"))
                results.checkNoTask(.matchRuleType("PrecompileModule"))
                results.checkTask(.matchRuleType("CompileC")) { compileTask in
                    results.checkTaskOutput(compileTask) { compileOutput in
                        XCTAssertMatch(compileOutput.stringValue, .contains("Apple clang version"))
                    }
                }

                results.checkNoErrors()
                results.checkRemark(.prefix("Explicit modules is enabled but the compiler was not recognized"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func outputPath() async throws {
        try await withTemporaryDirectory { tmpDir in
            func outputPathTest(given outputPathBuildSetting: String?, expected outputPath: Path, sourceLocation: SourceLocation = #_sourceLocation) async throws {
                let outputBuildSettings: [String: String] = outputPathBuildSetting.map {
                    ["CLANG_EXPLICIT_MODULES_OUTPUT_PATH": $0]
                } ?? [:]

                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDir,
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                children: [
                                    TestFile("file.c"),
                                ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                ].merging(outputBuildSettings, uniquingKeysWith: { a, b in b }))],
                            targets: [
                                TestStandardTarget(
                                    "Library",
                                    type: .staticLibrary,
                                    buildPhases: [
                                        TestSourcesBuildPhase(["file.c"]),
                                    ]),
                            ])])

                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                    stream <<<
            """
            #include <stdio.h>
            int something = 1;
            """
                }

                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in

                    results.checkNoErrors()

                    try results.checkTask(.matchRuleType("ScanDependencies")) { task in
                        let payload = try #require((task.payload as? ClangTaskPayload)?.explicitModulesPayload)

                        #expect(payload.sourcePath == tmpDir.join("aProject/file.c"))
                        #expect(payload.outputPath == outputPath)
                    }

                    try results.checkTasks(.matchRuleType("PrecompileModule")) { tasks in
                        #expect(tester.fs.exists(outputPath), sourceLocation: sourceLocation)
                        let modulesOutputDirContents = try tester.fs.listdir(outputPath)
                        for fileExtension in ["pcm", "dia", "d"] {
                            #expect(modulesOutputDirContents.filter({ $0.hasSuffix(fileExtension) }).count == tasks.count)
                        }
                    }

                    results.checkTask(.matchRuleType("CompileC")) { task in
                        // Need to check that the path is correct, but command line doesn't match until rdar://59354519 is resolved
                    }
                }
            }

            try await outputPathTest(given: nil, expected: tmpDir.join("aProject/build/ExplicitPrecompiledModules"))
            try await outputPathTest(given: "$(SRCROOT)/Modules", expected: tmpDir.join("aProject/Modules"))
            try await outputPathTest(given: "$(PER_ARCH_OBJECT_FILE_DIR)/Modules", expected: tmpDir.join("aProject/build/aProject.build/Debug/Library.build/Objects-normal/x86_64/Modules"))
            try await outputPathTest(given: "$(BUILT_PRODUCTS_DIR)/Modules", expected: tmpDir.join("aProject/build/Debug/Modules"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesSharingOfDependencies() async throws {
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
                                TestFile("mod_nested.h"),
                                TestFile("mod.h"),
                                TestFile("module.modulemap"),
                                TestFile("file_1.c"),
                                TestFile("file_2.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "CLANG_EXPLICIT_MODULES_OUTPUT_PATH": "$OBJROOT/ExplicitModules/$TARGET_NAME",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library_1",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                            TestStandardTarget(
                                "Library_2",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_2.c"]),
                                ]),
                            TestStandardTarget(
                                "Library_1_2",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_1.c", "file_2.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
                """
                module mod_nested { header "mod_nested.h" }
                module mod        { header "mod.h"        }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod_nested.h")) { stream in
                stream <<<
                """
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod.h")) { stream in
                stream <<<
                """
                #include "mod_nested.h"
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
                """
                #include "mod.h"
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_2.c")) { stream in
                stream <<<
                """
                #include "mod.h"
                """
            }

            let parameters = BuildParameters(configuration: "Debug")

            let target_1 = try #require(tester.workspace.targets(named: "Library_1").only)
            let target_2 = try #require(tester.workspace.targets(named: "Library_2").only)
            try await tester.checkBuild(runDestination: .macOS, buildRequest: BuildRequest(parameters: parameters, buildTargets: [.init(parameters: parameters, target: target_1), .init(parameters: parameters, target: target_2)], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)) { results in

                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                // Check that the discovered modules are not being shared between targets.
                results.checkTasks(.matchRuleType("PrecompileModule")) { scanTasks in
                    #expect(scanTasks.count == 4)
                }

                results.checkTasks(.matchRuleType("CompileC")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                results.checkNoDiagnostics()
            }

            let target_1_2 = try #require(tester.workspace.targets(named: "Library_1_2").only)
            try await tester.checkBuild(runDestination: .macOS, buildRequest: BuildRequest(parameters: parameters, buildTargets: [.init(parameters: parameters, target: target_1_2)], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)) { results in

                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                // Check that the discovered modules are being shared within the target.
                results.checkTasks(.matchRuleType("PrecompileModule")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                results.checkTasks(.matchRuleType("CompileC")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func sharingBetweenTargets() async throws {

        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("mod_nested.h"),
                                TestFile("mod.h"),
                                TestFile("module.modulemap"),
                                TestFile("file_1.c"),
                                TestFile("file_2.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library_1",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                            TestStandardTarget(
                                "Library_2",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_2.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
            """
            module mod_nested { header "mod_nested.h" }
            module mod        { header "mod.h"        }
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod_nested.h")) { stream in
                stream <<<
            """
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod.h")) { stream in
                stream <<<
            """
            #include "mod_nested.h"
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
            """
            #include "mod.h"
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_2.c")) { stream in
                stream <<<
            """
            #include "mod.h"
            """
            }

            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in

                for targetName in ["Library_1", "Library_2"] {
                    results.checkTaskExists(.matchTargetName(targetName), .matchRuleType("ScanDependencies"))
                    results.checkTaskExists(.matchTargetName(targetName), .matchRuleType("CompileC"))
                }

                // Precompiling modules is not target specific so we have one per module
                results.checkTaskExists(.matchRulePattern(["PrecompileModule", .contains("mod-")]))
                results.checkTaskExists(.matchRulePattern(["PrecompileModule", .contains("mod_nested-")]))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireDependencyScanner, .requireDependencyScannerWorkingDirectoryOptimization)
    func sharingBetweenProjects() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("mod_nested.h"),
                                TestFile("mod.h"),
                                TestFile("module.modulemap"),
                                TestFile("file_1.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "CLANG_EXPLICIT_MODULES_OUTPUT_PATH": "\(tmpDir.join("clangmodules").str)",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library_1",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                        ]), TestProject(
                            "aProject2",
                            groupTree: TestGroup(
                                "Sources",
                                children: [
                                    TestFile("file_2.c"),
                                ]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                    "HEADER_SEARCH_PATHS": "$(inherited) \(tmpDir.join("Test/aProject").str)",
                                    "CLANG_EXPLICIT_MODULES_OUTPUT_PATH": "\(tmpDir.join("clangmodules").str)",
                                ])],
                            targets: [
                                TestStandardTarget(
                                    "Library_2",
                                    type: .staticLibrary,
                                    buildPhases: [
                                        TestSourcesBuildPhase(["file_2.c"]),
                                    ]),
                            ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/module.modulemap")) { stream in
                stream <<<
            """
            module mod { header "mod.h" }
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mod.h")) { stream in
                stream <<<
            """
            void foo(void) {}
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
            """
            #include "mod.h"
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject2/file_2.c")) { stream in
                stream <<<
            """
            #include "mod.h"
            """
            }

            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) + tester.workspace.projects[1].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in

                for targetName in ["Library_1", "Library_2"] {
                    results.checkTaskExists(.matchTargetName(targetName), .matchRuleType("ScanDependencies"))
                    results.checkTaskExists(.matchTargetName(targetName), .matchRuleType("CompileC"))
                }

                // We should optimize out the working directory and only build one variant of "mod"
                results.checkTasks(.matchRulePattern(["PrecompileModule", .contains("mod-")])) { tasks in
                    #expect(tasks.count == 1)
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuildBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
            """
            #include <stdio.h>
            int something = 1;
            """
            }

            // Clean build
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("ScanDependencies"))
                results.checkTaskExists(.matchRuleType("CompileC"))

                results.checkTasks(.matchRuleType("PrecompileModule")) { _ in }

                results.checkNoDiagnostics()
            }

            // Null build
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)

            // Touch the source file to trigger a new scan.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
            """
            #include <stdio.h>
            int something = 2;
            """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("ScanDependencies"))
                results.checkTaskExists(.matchRuleType("CompileC"))

                results.checkTasks(.matchRuleType("PrecompileModule")) { _ in }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalTUChangeDoesNotForceModuleRebuilds() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
            """
            #include <stdio.h>
            int something = 1;
            """
            }

            // Clean build
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("ScanDependencies"))
                results.checkTaskExists(.matchRuleType("CompileC"))
                results.checkTasks(.matchRuleType("PrecompileModule")) { _ in }

                results.checkNoDiagnostics()
            }

            // Null build
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)

            // Touch the source file to trigger a new scan.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
            """
            #include <stdio.h>
            int something = 2;
            """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("ScanDependencies"))
                results.checkTaskExists(.matchRuleType("CompileC"))

                // We shouldn't need to recompile any modules.
                results.checkNoTask(.matchRuleType("PrecompileModule"))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuildsDoNotRebuildModuleDepsWhenModuleChanges() async throws {

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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <Framework/Framework.h>

                void test() {
                    NSLog(@"%@", [[Shared alloc] init]);
                }

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            // Build and check that we build the Framework module once, and we build other module dependencies.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("/Framework-"))) { precompileFrameworkTasks in
                    #expect(precompileFrameworkTasks.count == 1)
                }
                results.checkTasks(.matchRuleType("PrecompileModule")) { precompileOtherModuleTasks in
                    #expect(precompileOtherModuleTasks.count > 0)
                }
                results.checkNoDiagnostics()
            }

            // Update the framework module, but none of its dependencies. The framework module should rebuild, but the others should not.
            try tester.fs.touch(testWorkspace.sourceRoot.join("aProject/Framework.h"))
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("/Framework-"))) { precompileFrameworkTasks in
                    #expect(precompileFrameworkTasks.count == 1)
                }
                results.checkTasks(.matchRuleType("PrecompileModule")) { precompileOtherModuleTasks in
                    #expect(precompileOtherModuleTasks.count == 0)
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesIncrementalBuildInvalidatingProjectModule() async throws {

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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <Framework/Framework.h>

                void test() {
                    NSLog(@"%@", [[Shared alloc] init]);
                }

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // There be 2 scanning actions.
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 2)
                }
                results.checkNoDiagnostics()
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                @interface SharedTwo: NSObject {}
                @end
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // There should 2 scanning actions.
                // Both files will recompile.
                results.checkTasks(.matchRuleType("ScanDependencies")) { compileTasks in
                    #expect(compileTasks.count == 2)
                }

                // Both files will recompile.
                results.checkTasks(.matchRuleType("CompileC")) { compileTasks in
                    #expect(compileTasks.count == 2)
                }

                // The module for Framework will be rebuilt.
                results.checkTask(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("Framework"))) { _ in }

                results.consumeTasksMatchingRuleTypes(["Gate", "ClangStatCache", "CpHeader", "Ld", "Libtool", "GenerateTAPI", "ProcessSDKImports"])

                results.checkNoTask()

                results.checkNoDiagnostics()
            }

            // Introduce a new module dependency
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                #include <SceneKit/SceneKit.h>
                @interface Shared: NSObject {}
                @end

                @interface SharedTwo: NSObject {}
                @end
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // There should 2 scanning actions.
                // Both files will recompile.
                results.checkTasks(.matchRuleType("ScanDependencies")) { compileTasks in
                    #expect(compileTasks.count == 2)
                }

                // Both files will recompile.
                results.checkTasks(.matchRuleType("CompileC")) { compileTasks in
                    #expect(compileTasks.count == 2)
                }

                results.consumeTasksMatchingRuleTypes(["Gate", "ClangStatCache", "CpHeader", "Ld", "Libtool", "GenerateTAPI", "PrecompileModule", "ProcessSDKImports"])

                results.checkNoTask()

                results.checkNoDiagnostics()
            }

        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuildsDoNotAccumulateModuleVariantsWhenSignaturesChange() async throws {

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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <Framework/Framework.h>

                void test() {
                    NSLog(@"%@", [[Shared alloc] init]);
                }

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            // Build and check that we build the Framework module once.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("/Framework-"))) { precompileFrameworkTasks in
                    #expect(precompileFrameworkTasks.count == 1)
                }
                results.checkNoDiagnostics()
            }

            // Update a header in the module and add a preprocessor definition to be picked up in the module hash. We should only build the new copy of the module, as we no longer need the old one.
            try tester.fs.touch(testWorkspace.sourceRoot.join("aProject/Framework.h"))
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["GCC_PREPROCESSOR_DEFINITIONS": "FOO"]), runDestination: .macOS, persistent: true) { results in
                // There be 2 scanning actions.
                results.checkTasks(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("/Framework-"))) { precompileFrameworkTasks in
                    #expect(precompileFrameworkTasks.count == 1)
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuildsDoNotAccumulateModuleVariantsWhenImportedModulesChange() async throws {

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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #import <Framework/Framework.h>

                void test() {
                }

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #import <Foundation/Foundation.h>
                """
            }

            // Build and check that we build the Framework module once.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("/Framework-"))) { precompileFrameworkTasks in
                    #expect(precompileFrameworkTasks.count == 1)
                }
                results.checkNoDiagnostics()
            }

            // Update a header in the module to add a new module dependency. We should only build the new copy of the module, as we no longer need the old one.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #import <Foundation/Foundation.h>
                #import <CoreData/CoreData.h>
                """
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // There be 2 scanning actions.
                results.checkTasks(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("/Framework-"))) { precompileFrameworkTasks in
                    #expect(precompileFrameworkTasks.count == 1)
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalUpdateToTransitiveModuleDependency() async throws {

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
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared.m"),
                                TestFile("Framework2.h"),
                                TestFile("Shared2.h"),
                                TestFile("Shared2.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                    ]),
                                    TestFrameworksBuildPhase(["Framework2.framework"]),
                                ], dependencies: ["Framework2"]),
                            TestStandardTarget(
                                "Framework2",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared2.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework2.h", headerVisibility: .public),
                                        TestBuildFile("Shared2.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <Framework/Framework.h>

                void test() {
                    NSLog(@"%@", [[Shared alloc] init]);
                }

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                """
                #include <Framework/Shared.h>
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                #include <Framework2/Framework2.h>
                @interface Shared: Shared2 {}
                @end

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework2.h")) { stream in
                stream <<<
                """
                #include <Framework2/Shared2.h>
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared2.h")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                @interface Shared2: NSObject {}
                @end

                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared2.m")) { stream in
                stream <<<
                """
                #include "Shared2.h"
                @implementation Shared2 {}
                @end
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 3)
                }
                results.checkTasks(.matchRulePattern(["PrecompileModule", .contains("Framework-")])) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRulePattern(["PrecompileModule", .contains("Framework2-")])) { tasks in
                    #expect(tasks.count == 2)
                }
                results.checkNoDiagnostics()
            }

            // Change the transitively depended-upon module
            try tester.fs.touch(testWorkspace.sourceRoot.join("aProject/Shared2.h"))

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("ScanDependencies")) { scanTasks in
                    #expect(scanTasks.count == 3)
                }

                results.checkTasks(.matchRulePattern(["PrecompileModule", .contains("Framework-")])) { tasks in
                    #expect(tasks.count == 1)
                }
                results.checkTasks(.matchRulePattern(["PrecompileModule", .contains("Framework2-")])) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkNoTask(.matchRuleType("ScanDependencies"))
                results.checkNoTask(.matchRuleType("PrecompileModule"))
                results.checkNoDiagnostics()
            }

        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalHeaderRename() async throws {

        try await withTemporaryDirectory { (tmpDir: NamedTemporaryDirectory) in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.path.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("SharedNew.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                        TestBuildFile("SharedNew.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, temporaryDirectory: tmpDir)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                    """
                    #include <Framework/Framework.h>

                    void test() {
                        NSLog(@"%@", [[Shared alloc] init]);
                    }

                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                    """
                    #include <Framework/Shared.h>
                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                    """
                    #include <Foundation/Foundation.h>
                    @interface Shared: NSObject {}
                    @end

                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                    """
                    #include "Shared.h"
                    @implementation Shared {}
                    @end
                    """
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["EXCLUDED_SOURCE_FILE_NAMES": "SharedNew.h"]), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try tester.fs.move(testWorkspace.sourceRoot.join("aProject/Shared.h"), to: testWorkspace.sourceRoot.join("aProject/SharedNew.h"))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                    """
                    #include <Framework/SharedNew.h>
                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                    """
                    #include "SharedNew.h"
                    @implementation Shared {}
                    @end
                    """
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["EXCLUDED_SOURCE_FILE_NAMES": "Shared.h"]), runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("Framework-")))
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("file.m"))
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("Shared.m"))
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItemBasename("file.o"))
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItemBasename("Shared.o"))
                results.consumeTasksMatchingRuleTypes(["Gate", "ClangStatCache", "CpHeader", "GenerateTAPI", "Ld", "Libtool", "ProcessSDKImports"])
                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuildHeaderRemoval() async throws {

        try await withTemporaryDirectory { (tmpDir: NamedTemporaryDirectory) in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.path.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.m"),
                                TestFile("Framework.h"),
                                TestFile("Shared.h"),
                                TestFile("Shared2.h"),
                                TestFile("Shared.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Shared.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                        TestBuildFile("Shared.h", headerVisibility: .public),
                                        TestBuildFile("Shared2.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, temporaryDirectory: tmpDir)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                    """
                    #include <Framework/Framework.h>

                    void test() {
                        NSLog(@"%@", [[Shared alloc] init]);
                    }

                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                    """
                    #include <Framework/Shared.h>
                    #include <Framework/Shared2.h>
                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.h")) { stream in
                stream <<<
                    """
                    #include <Foundation/Foundation.h>
                    @interface Shared: NSObject {}
                    @end

                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared2.h")) { stream in
                stream <<< ""
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Shared.m")) { stream in
                stream <<<
                    """
                    #include "Shared.h"
                    @implementation Shared {}
                    @end
                    """
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try tester.fs.remove(testWorkspace.sourceRoot.join("aProject/Shared2.h"))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                    """
                    #include <Framework/Shared.h>
                    """
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["EXCLUDED_SOURCE_FILE_NAMES": "Shared2.h"]), runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("PrecompileModule"), .matchRuleItemPattern(.contains("Framework-")))
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("file.m"))
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItemBasename("file.o"))
                results.consumeTasksMatchingRuleTypes(["Gate", "ClangStatCache", "CpHeader", "GenerateTAPI", "Ld", "Libtool"])
                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func addingTranslationUnit() async throws {

        try await withTemporaryDirectory { (tmpDir: NamedTemporaryDirectory) in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.path.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.m"),
                                TestFile("file2.m"),
                                TestFile("Framework.h"),
                                TestFile("Framework.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m", "file2.m"]),
                                    TestFrameworksBuildPhase(["Framework.framework"]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["Framework.m"]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Framework.h", headerVisibility: .public),
                                    ]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, temporaryDirectory: tmpDir)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                    """
                    #include <Framework/Framework.h>

                    void test() {
                        NSLog(@"%@", [[Shared alloc] init]);
                    }

                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.h")) { stream in
                stream <<<
                    """
                    #include <Foundation/Foundation.h>
                    @interface Shared: NSObject {}
                    @end
                    """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework.m")) { stream in
                stream <<<
                    """
                    #include "Framework.h"
                    @implementation Shared {}
                    @end
                    """
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["EXCLUDED_SOURCE_FILE_NAMES": "file2.m"]), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.m")) { stream in
                stream <<<
                    """
                    #include <Framework/Framework.h>

                    void test2() {
                        NSLog(@"%@ two", [[Shared alloc] init]);
                    }

                    """
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("file.m"))
                results.checkTaskExists(.matchRuleType("ScanDependencies"), .matchRuleItemBasename("file2.m"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func objectFileVerifier() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "CLANG_ENABLE_EXPLICIT_MODULES_OBJECT_FILE_VERIFIER": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file.m"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.m")) { stream in
                stream <<<
                """
                #include <Foundation/Foundation.h>
                int something = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Because the verifier is enabled, we should produce explicit modules tasks, plus an implicit modules compile task.
                results.checkTaskExists(.matchRuleType("ScanDependencies"))
                results.checkTaskExists(.matchRuleType("CompileC"), .matchRuleItem("(implicit-copy)"))
                results.checkTaskExists(.matchRuleType("CompileC"))
                results.checkTasks(.matchRuleType("PrecompileModule")) { _ in }
                results.checkTasks(.matchRuleType("Strip")) { tasks in
                    #expect(tasks.count == 2)
                }

                // Verifier diff task
                results.checkTaskExists(.matchRuleType("Diff"))

                // We should not diagnose any duplicate tasks, outputs, etc.
                // rdar://100590477 (Object file diffs in debug info when building projects with clang explicit modules on/off)
                results.checkError(.prefix("Command Diff failed."), failIfNotFound: false)
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func dependencyInfoIngestion() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
            """
            #include <stdio.h>
            int something = 1;
            """
            }

            // Clean build
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("ScanDependencies"))
                results.checkTaskExists(.matchRuleType("CompileC"))

                results.checkTasks(.matchRuleType("PrecompileModule")) { _ in }

                results.checkNoDiagnostics()
            }

            // Remove the object file so compilation has to re-run on the next build, but scanning does not.
            try tester.fs.remove(testWorkspace.sourceRoot.join("aProject/Build/aProject.build/Debug/Library.build/Objects-normal/x86_64/file.o"))

            // The incremental build should succeed because dependencies will be ingested from disk.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"))
                results.checkTaskExists(.matchRuleType("CompileC"))

                results.checkNoTask(.matchRuleType("PrecompileModule"))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesWithResponseFiles() async throws {
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
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "CLANG_USE_RESPONSE_FILE": "YES",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let responseFileTask: Task = try results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".resp"))) { $0 }
                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("CompileC")) { $0 }
                results.check(event: .taskHadEvent(responseFileTask, event: .completed), precedes: .taskHadEvent(scanTask, event: .started))
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func disablement() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("file.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "CLANG_ENABLE_EXPLICIT_MODULES": "NO",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
            """
            #include <stdio.h>
            int something = 1;
            """
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"))
                results.checkNoTask(.matchRuleType("PrecompileModule"))

                results.checkTaskExists(.matchRuleType("CompileC"))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func diagnosingMissingTargetDependencies() async throws {

        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Framework1.h"),
                                TestFile("Framework2.h"),
                                TestFile("file_1.c"),
                                TestFile("file_2.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "DEFINES_MODULE": "YES",
                                "VALID_ARCHS": "arm64",
                                "DSTROOT": tmpDir.join("dstroot").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Framework1",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("Framework1.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                            TestStandardTarget(
                                "Framework2",
                                type: .framework,
                                buildPhases: [
                                    // Ensure the we always happen to build the targets in the right order, even though the dependency is missing.
                                    TestShellScriptBuildPhase(name: "Sleep", originalObjectID: "A", contents: "sleep 5", alwaysOutOfDate: true),
                                    TestHeadersBuildPhase([TestBuildFile("Framework2.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["file_2.c"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework1.h")) { stream in
                stream <<<
            """
            void foo(void);
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
            """
            #include <Framework1/Framework1.h>
            void foo(void) {}
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework2.h")) { stream in
                stream <<<
            """
            #include <Framework1/Framework1.h>
            void bar(void);
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_2.c")) { stream in
                stream <<<
            """
            #include <Framework2/Framework2.h>
            void bar(void) { foo(); }
            """
            }

            for (warningLevel, destination) in [(BooleanWarningLevel.yes, RunDestinationInfo.iOS), (BooleanWarningLevel.yes, RunDestinationInfo.macOS), (BooleanWarningLevel.no, RunDestinationInfo.macOS)] {
                let parameters = BuildParameters(configuration: "Debug", overrides: ["DIAGNOSE_MISSING_TARGET_DEPENDENCIES": warningLevel.rawValue])
                let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

                try await tester.checkBuild(runDestination: destination, buildRequest: buildRequest, persistent: true) { results in
                    switch warningLevel {
                    case .yes:
                        results.checkWarning("'Framework2' is missing a dependency on 'Framework1' because dependency scan of 'file_2.c' discovered a dependency on 'Framework1' (in target 'Framework2' from project 'aProject')")
                    case .yesError:
                        results.checkError("'Framework2' is missing a dependency on 'Framework1' because dependency scan of 'file_2.c' discovered a dependency on 'Framework1' (in target 'Framework2' from project 'aProject')")
                    default:
                        break
                    }
                    results.checkWarning(.prefix("tasks in 'Copy Headers' are delayed by unsandboxed script phases"))
                    results.checkNoDiagnostics()
                }

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func clangExplicitModulesScannerDependencyRollupIsComplete() async throws {
        try await withTemporaryDirectory { tmpDirParentPath in
            let tmpDirPath = tmpDirParentPath.join("has whitespace")
            try localFS.createDirectory(tmpDirPath, recursive: true)
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
                                TestFile("A.h"),
                                TestFile("file2.c"),
                                TestFile("file3.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget("All", dependencies: ["A", "B", "C"]),
                            TestStandardTarget(
                                "A",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                    ])],
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["file.c"]),
                                ]),
                            TestStandardTarget(
                                "B",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file2.c"]),
                                ], dependencies: ["A"]),
                            TestStandardTarget(
                                "C",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file3.c"]),
                                ], dependencies: ["B"]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                int foo(void) {
                    return 42;
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/A.h")) { stream in
                stream <<<
                """
                int foo(void);
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file2.c")) { stream in
                stream <<<
                """
                #include <A/A.h>
                void f(void) {
                    int x = foo();
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file3.c")) { stream in
                stream <<<
                """
                #include <A/A.h>
                void f(void) {
                    int y = foo();
                }
                """
            }

            // Run a clean build
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)

            // Touch A's header
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/A.h")) { stream in
                stream <<<
                """
                // Comment
                int foo(void);
                """
            }

            // Run an incremental build. Both B and C should rescan and recompile.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleItem("PrecompileModule"))
                results.checkTaskExists(.matchTargetName("B"), .matchRuleItem("ScanDependencies"))
                results.checkTaskExists(.matchTargetName("C"), .matchRuleItem("ScanDependencies"))
                results.checkTaskExists(.matchTargetName("B"), .matchRuleItem("CompileC"))
                results.checkTaskExists(.matchTargetName("C"), .matchRuleItem("CompileC"))
            }

            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModulesProducesCorrectDependencyInfoWhenPathContainsWhitespace() async throws {
        try await withTemporaryDirectory { tmpDirParentPath in
            let tmpDirPath = tmpDirParentPath.join("has whitespace")
            try localFS.createDirectory(tmpDirPath, recursive: true)
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
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
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

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file.c")) { stream in
                stream <<<
                """
                #include <stdio.h>
                int something = 1;
                """
            }

            // The build should succeed if we produced dependency info which can be parsed correctly.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
