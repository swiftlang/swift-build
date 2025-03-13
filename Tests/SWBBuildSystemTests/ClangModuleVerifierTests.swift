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

import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct ClangModuleVerifierTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func fileNameMap() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            let archs = ["arm64", "x86_64"]
            let targetName = "Orange"
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Orange.h"),
                                TestFile("Orange2.h"),
                                TestFile("Orange3.h"),
                                TestFile("main.m"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS": archs.joined(separator: " "),
                                "DEFINES_MODULE": "YES",
                                "ENABLE_MODULE_VERIFIER": "YES",
                                "MODULE_VERIFIER_KIND": "builtin",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11",
                                "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                targetName,
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Orange.h", headerVisibility: .public),
                                        TestBuildFile("Orange2.h", headerVisibility: .public),
                                        TestBuildFile("Orange3.h", headerVisibility: .public),
                                    ]),
                                    TestSourcesBuildPhase([
                                        "main.m",
                                    ]),
                                ]),
                        ])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try tester.fs.createDirectory(SRCROOT.join("Sources"), recursive: true)
            try tester.fs.write(SRCROOT.join("Orange.h"), contents: """
                // no include of Orange2.h -> incomplete umbrella
                #include "Orange3.h"
                """)
            try tester.fs.write(SRCROOT.join("Orange2.h"), contents: "")
            try tester.fs.write(SRCROOT.join("Orange3.h"), contents: "")
            try tester.fs.write(SRCROOT.join("main.m"), contents: """
                #include <Orange/Orange.h>
                """)

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Check that the diagnostic has the source directory path.
                results.checkError(.and(.prefix(SRCROOT.join("Orange.h").str), .contains("umbrella header for module 'Orange' does not include header 'Orange2.h'")))
                results.checkError(.and(.prefix(SRCROOT.join("Orange.h").str), .contains("double-quoted include \"Orange3.h\" in framework header, expected angle-bracketed instead"))) { diag in
                    #expect(diag.fixIts.count == 1)
                    guard diag.fixIts.count >= 1 else { return true }
                    #expect(diag.fixIts[0].sourceRange.path == SRCROOT.join("Orange.h"))
                    #expect(diag.fixIts[0].textToInsert == "<Orange/Orange3.h>")
                    return true
                }
                results.checkNoNotes()
                // Handle additional diagnostics that may be present depending on explicit vs. implicit modules.
                results.checkError(.contains("could not build module 'Orange'"), failIfNotFound: false)
                results.checkError(.contains("could not build module 'Test'"), failIfNotFound: false)
                results.checkError(.contains("exited with status"), failIfNotFound: false)
                results.checkError(.contains("exited with status"), failIfNotFound: false)
                results.checkError(.contains("module file not found"), failIfNotFound: false)
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func explicitModules() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            let archs = ["arm64", "x86_64"]
            let targetName = "Orange"
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Orange.h"),
                                TestFile("Orange.defs"),
                                TestFile("main.m"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS": archs.joined(separator: " "),
                                "CLANG_ENABLE_MODULES": "YES",
                                "DEFINES_MODULE": "YES",
                                "ENABLE_MODULE_VERIFIER": "YES",
                                "MODULE_VERIFIER_KIND": "builtin",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11",
                                "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                targetName,
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Orange.h", headerVisibility: .public),
                                        TestBuildFile("Orange.defs", headerVisibility: .public),
                                    ]),
                                    TestSourcesBuildPhase([
                                        "main.m",
                                    ]),
                                ]),
                        ])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try tester.fs.createDirectory(SRCROOT.join("Sources"), recursive: true)
            try tester.fs.write(SRCROOT.join("Orange.h"), contents: """
                #include <Orange/Orange.defs>
                """)
            try tester.fs.write(SRCROOT.join("Orange.defs"), contents: "")
            try tester.fs.write(SRCROOT.join("main.m"), contents: """
                #include <Orange/Orange.h>
                """)

            // A regular build will just build the correct architecture.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()

                // There are no non-verification PrecompileModule tasks.
                results.checkNoTask(.matchRuleType("PrecompileModule"))

                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies"), .matchRuleItem("com.apple.compilers.llvm.clang.1_0.verify_module")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("VerifyModuleC")) { $0 }

                // Make sure scanning happens before compilation...
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                results.checkTasks(.matchRuleType("VerifyPrecompileModule")) { tasks in
                    for task in tasks {
                        // ... and make sure pcms also get precompiled before compilation.
                        results.check(event: .taskHadEvent(task, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))
                        let base = Path(task.ruleInfo[1]).basenameWithoutSuffix
                        let moduleName = base.prefix(upTo: base.firstIndex(of: "-") ?? base.endIndex)
                        #expect(["Test", "Orange"].contains(moduleName))
                        if moduleName == "Test" {
                            #expect(task.execDescription == "Verifying import of Clang module Orange")
                        } else {
                            #expect(task.execDescription == "Verifying compile of Clang module Orange")
                        }
                        results.checkTaskResult(task, expected: .succeeded())
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule), .requireDependencyScannerPlusCaching, .requireCompilationCaching,
          .flaky("A handful of Swift Build CAS tests fail when running the entire test suite"), .bug("rdar://146781403"))
    func cachedBuild() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            let archs = ["arm64", "x86_64"]
            let targetName = "Orange"
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Orange.h"),
                                TestFile("Orange.defs"),
                                TestFile("main.m"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS": archs.joined(separator: " "),
                                "CLANG_ENABLE_MODULES": "YES",
                                "DEFINES_MODULE": "YES",
                                "ENABLE_MODULE_VERIFIER": "YES",
                                "MODULE_VERIFIER_KIND": "builtin",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11",
                                "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c",
                                "PRODUCT_NAME": "$(TARGET_NAME)",

                                "CLANG_ENABLE_COMPILE_CACHE": "YES",
                                "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
                                "OTHER_MODULE_VERIFIER_FLAGS": "-- -Rcompile-job-cache",
                                "DSTROOT": tmpDirPath.join("dstroot").str,
                            ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                targetName,
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Orange.h", headerVisibility: .public),
                                        TestBuildFile("Orange.defs", headerVisibility: .public),
                                    ]),
                                    TestSourcesBuildPhase([
                                        "main.m",
                                    ]),
                                ]),
                        ])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try tester.fs.createDirectory(SRCROOT.join("Sources"), recursive: true)
            try tester.fs.write(SRCROOT.join("Orange.h"), contents: """
                #include <Orange/Orange.defs>
                """)
            try tester.fs.write(SRCROOT.join("Orange.defs"), contents: "")
            try tester.fs.write(SRCROOT.join("main.m"), contents: """
                #include <Orange/Orange.h>
                """)

            // A regular build will just build the correct architecture.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // There are no non-verification PrecompileModule tasks.
                results.checkNoTask(.matchRuleType("PrecompileModule"))

                let scanTask: Task = try results.checkTask(.matchRuleType("ScanDependencies"), .matchRuleItem("com.apple.compilers.llvm.clang.1_0.verify_module")) { $0 }
                let compileTask: Task = try results.checkTask(.matchRuleType("VerifyModuleC")) { task in
                    results.checkWarning(.contains("compile job cache miss "))
                    return task
                }

                // Make sure scanning happens before compilation...
                results.check(event: .taskHadEvent(scanTask, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))

                results.checkTasks(.matchRuleType("VerifyPrecompileModule")) { tasks in
                    for task in tasks {
                        // ... and make sure pcms also get precompiled before compilation.
                        results.check(event: .taskHadEvent(task, event: .completed), precedes: .taskHadEvent(compileTask, event: .started))
                        let base = Path(task.ruleInfo[1]).basenameWithoutSuffix
                        let moduleName = base.prefix(upTo: base.firstIndex(of: "-") ?? base.endIndex)
                        #expect(["Test", "Orange"].contains(moduleName))
                        if moduleName == "Test" {
                            #expect(task.execDescription == "Verifying import of Clang module Orange")
                        } else {
                            #expect(task.execDescription == "Verifying compile of Clang module Orange")
                        }
                        results.checkTaskResult(task, expected: .succeeded())
                        results.checkWarning(.contains("compile job cache miss "))
                    }
                }
            }
            // Clean the build to trigger a cached build.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTask(.matchRuleType("VerifyModuleC")) { task in
                    results.checkWarning(.contains("compile job cache hit "))
                    results.checkTaskResult(task, expected: .succeeded())
                }

                results.checkTasks(.matchRuleType("VerifyPrecompileModule")) { tasks in
                    for task in tasks {
                        results.checkTaskResult(task, expected: .succeeded())
                        results.checkWarning(.contains("compile job cache hit "))
                    }
                }
            }
        }
    }
}
