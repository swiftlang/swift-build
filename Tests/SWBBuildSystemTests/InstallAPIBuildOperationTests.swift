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

import SwiftBuildTestSupport
import SWBTestSupport

import SWBBuildSystem
import SWBProtocol
import SWBCore
import SWBTaskExecution
import SWBUtil

import Testing

@Suite
fileprivate struct InstallAPIBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func dylibIncrementalInstallAPI() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("main.c"), TestFile("Public.h"), TestFile("Private.h")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SUPPORTS_TEXT_BASED_API": "YES",
                                "INSTALL_GROUP": "",
                                "INSTALL_OWNER": "",
                                "DSTROOT": tmpDirPath.join("DSTROOT").str
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Dylib", type: .dynamicLibrary,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Public.h", headerVisibility: .public),
                                        TestBuildFile("Private.h", headerVisibility: .private)
                                    ]),
                                    TestSourcesBuildPhase(["main.c"])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c"), body: {
                $0 <<< """
                    void f(void) {}
                    void g(void) {}
                    """
            })

            for action in [BuildAction.build, BuildAction.install] {
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: { $0 <<< "void f(void);" })

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Private.h"), body: { $0 <<< "void g(void);" })

                let parameters = BuildParameters(action: action, configuration: "Debug")
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoDiagnostics()
                }

                try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true)

                // Update a public header.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: { $0 <<< "void f(void); // prototype" })

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoDiagnostics()
                }

                try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true)

                // Update a private header.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Private.h"), body: { $0 <<< "void g(void); // prototype" })

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoDiagnostics()
                }

                try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true)
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkIncrementalInstallAPI() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("main.c"), TestFile("Public.h"), TestFile("Private.h")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SUPPORTS_TEXT_BASED_API": "YES",
                                "INSTALL_GROUP": "",
                                "INSTALL_OWNER": "",
                                "DSTROOT": tmpDirPath.join("DSTROOT").str
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Framework", type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Public.h", headerVisibility: .public),
                                        TestBuildFile("Private.h", headerVisibility: .private)
                                    ]),
                                    TestSourcesBuildPhase(["main.c"])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c"), body: {
                $0 <<< """
                    void f(void) {}
                    void g(void) {}
                    """
            })

            for action in [BuildAction.build, BuildAction.install] {
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: { $0 <<< "void f(void);" })

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Private.h"), body: { $0 <<< "void g(void);" })

                let parameters = BuildParameters(action: action, configuration: "Debug")
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoDiagnostics()
                }

                // Update a public header.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: { $0 <<< "void f(void); // prototype" })

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoDiagnostics()
                }

                try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true)

                // Update a private header.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Private.h"), body: { $0 <<< "void g(void); // prototype" })

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoDiagnostics()
                }

                try await tester.checkNullBuild(parameters: parameters, runDestination: .macOS, persistent: true)
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkIncrementalInstallAPIPostHeaderRemoval() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("main.c"), TestFile("Public.h"), TestFile("Private.h")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SUPPORTS_TEXT_BASED_API": "YES",
                                "INSTALL_GROUP": "",
                                "INSTALL_OWNER": "",
                                "DSTROOT": tmpDirPath.join("DSTROOT").str,
                                "TAPI_VERIFY_MODE": "ErrorsOnly",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Framework", type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Public.h", headerVisibility: .public),
                                        TestBuildFile("Private.h", headerVisibility: .private)
                                    ]),
                                    TestSourcesBuildPhase(["main.c"])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c"), body: {
                $0 <<< """
                    void f(void) {}
                    void g(void) {}
                    """
            })

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: { $0 <<< "void f(void);" })

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Private.h"), body: { $0 <<< "void g(void);" })

            for action in [BuildAction.build, BuildAction.install] {
                func parameters(excludePublicHeader: Bool, excludePrivateHeader: Bool) -> BuildParameters {
                    var overrides: [String: String] = [:]
                    if excludePublicHeader {
                        overrides["EXCLUDED_SOURCE_FILE_NAMES", default: ""].append("Public.h")
                    }
                    if excludePrivateHeader {
                        overrides["EXCLUDED_SOURCE_FILE_NAMES", default: ""].append(" Private.h")
                    }
                    return BuildParameters(action: action, configuration: "Debug", overrides: overrides)
                }
                try await tester.checkBuild(parameters: parameters(excludePublicHeader: false, excludePrivateHeader: false), runDestination: .macOS, persistent: true) { results in
                    try results.checkTask(.matchRuleType("GenerateTAPI")) { tapiTask in
                        let output = tapiTask.outputPaths[0]
                        let contents = try tester.fs.read(output).asString
                        #expect(contents.contains("_f"))
                        #expect(contents.contains("_g"))
                    }
                    results.checkNoDiagnostics()
                }

                try await tester.checkBuild(parameters: parameters(excludePublicHeader: true, excludePrivateHeader: false), runDestination: .macOS, persistent: true) { results in
                    try results.checkTask(.matchRuleType("GenerateTAPI")) { tapiTask in
                        let output = tapiTask.outputPaths[0]
                        let contents = try tester.fs.read(output).asString
                        #expect(!contents.contains("_f"))
                        #expect(contents.contains("_g"))
                    }
                    results.checkNoDiagnostics()
                }

                try await tester.checkNullBuild(parameters: parameters(excludePublicHeader: true, excludePrivateHeader: false), runDestination: .macOS, persistent: true)

                try await tester.checkBuild(parameters: parameters(excludePublicHeader: true, excludePrivateHeader: true), runDestination: .macOS, persistent: true) { results in
                    try results.checkTask(.matchRuleType("GenerateTAPI")) { tapiTask in
                        let output = tapiTask.outputPaths[0]
                        let contents = try tester.fs.read(output).asString
                        #expect(!contents.contains("_f"))
                        #expect(!contents.contains("_g"))
                    }
                    results.checkNoDiagnostics()
                }

                try await tester.checkNullBuild(parameters: parameters(excludePublicHeader: true, excludePrivateHeader: true), runDestination: .macOS, persistent: true)
                try await tester.checkBuild(parameters: parameters(excludePublicHeader: true, excludePrivateHeader: true), runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func installAPIHeaderPlatformFiltering() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("main.c"), TestFile("Public.h"), TestFile("Private.h")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SUPPORTS_TEXT_BASED_API": "YES",
                                "INSTALL_GROUP": "",
                                "INSTALL_OWNER": "",
                                "DSTROOT": tmpDirPath.join("DSTROOT").str
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Framework", type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Public.h", headerVisibility: .public),
                                        TestBuildFile("Private.h", headerVisibility: .private, platformFilters: PlatformFilter.iOSFilters)
                                    ]),
                                    TestSourcesBuildPhase(["main.c"])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c"), body: {
                $0 <<< """
                    void f(void) {}
                    void g(void) {}
                    """
            })

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: { $0 <<< "void f(void); void g(void);" })

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Private.h"), body: { $0 <<< "" })

            for action in [BuildAction.build, BuildAction.install] {
                let parameters = BuildParameters(action: action, configuration: "Debug")
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTask(.matchRuleType("GenerateTAPI")) { _ in }
                    results.checkNoDiagnostics()

                    let versionsPath = tmpDirPath.join("Test/aProject/build/Debug/Framework.framework/Versions/A")

                    results.checkFileExists(versionsPath.join("Headers"))

                    // PrivateHeaders should not exist because all headers were filtered out by platform filters.
                    results.checkFileDoesNotExist(versionsPath.join("PrivateHeaders"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func stubifyAvoidsRelinkingWhenExportedSymbolsDoNotChange() async throws {
        for supportsInstallAPI in ["YES", "NO"] {
            try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup("Sources", children: [TestFile("main.c"), TestFile("dep.c"), TestFile("Public.h")]),
                            buildConfigurations: [TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SUPPORTS_TEXT_BASED_API": supportsInstallAPI,
                                    "INSTALL_GROUP": "",
                                    "INSTALL_OWNER": "",
                                ]
                            )],
                            targets: [
                                TestStandardTarget(
                                    "Framework", type: .framework,
                                    buildPhases: [
                                        TestSourcesBuildPhase(["main.c"]),
                                        TestFrameworksBuildPhase(["Framework2.framework"])
                                    ], dependencies: ["Framework2"]),
                                TestStandardTarget(
                                    "Framework2", type: .framework,
                                    buildPhases: [
                                        TestHeadersBuildPhase([
                                            TestBuildFile("Public.h", headerVisibility: .public),
                                        ]),
                                        TestSourcesBuildPhase(["dep.c"])
                                    ]),
                            ])])
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c"), body: {
                    $0 <<< """
                        static void f(void) {

                        }
                        """
                })

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: {
                    $0 <<< """
                        void g(void);
                        """
                })

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/dep.c"), body: {
                    $0 <<< """
                        #include <stdio.h>
                        void g(void) {

                        }
                        """
                })

                let parameters = BuildParameters(action: .build, configuration: "Debug")
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkTaskExists(.matchTargetName("Framework"), .matchRuleType("CompileC"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("CompileC"))
                    results.checkTaskExists(.matchTargetName("Framework"), .matchRuleType("Ld"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("Ld"))
                    results.checkTaskExists(.matchTargetName("Framework"), .matchRuleType("GenerateTAPI"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("GenerateTAPI"))
                    results.checkNoDiagnostics()
                }

                // Change the dependency without changing the list of exported symbols - the dependent should not relink.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/dep.c"), body: {
                    $0 <<< """
                        #include <stdio.h>
                        void g(void) {
                        printf("foo");
                        }
                        """
                })

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkNoTask(.matchTargetName("Framework"), .matchRuleType("CompileC"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("CompileC"))
                    results.checkNoTask(.matchTargetName("Framework"), .matchRuleType("Ld"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("Ld"))
                    results.checkNoTask(.matchTargetName("Framework"), .matchRuleType("GenerateTAPI"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("GenerateTAPI"))
                    results.checkNoDiagnostics()
                }

                // Change exported symbols in the dependency, the dependency should relink (but the dependency does not need to recompile).
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/dep.c"), body: {
                    $0 <<< """
                        #include <stdio.h>
                        void h(void) {
                        printf("foo");
                        }
                        """
                })

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Public.h"), body: {
                    $0 <<< """
                        void h(void);
                        """
                })

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    results.checkNoTask(.matchTargetName("Framework"), .matchRuleType("CompileC"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("CompileC"))
                    results.checkTaskExists(.matchTargetName("Framework"), .matchRuleType("Ld"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("Ld"))
                    results.checkTaskExists(.matchTargetName("Framework"), .matchRuleType("GenerateTAPI"))
                    results.checkTaskExists(.matchTargetName("Framework2"), .matchRuleType("GenerateTAPI"))
                    results.checkNoDiagnostics()
                }
            }
        }
    }
}
