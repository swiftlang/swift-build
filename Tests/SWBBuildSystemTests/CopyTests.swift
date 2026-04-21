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

import SWBBuildSystem
import SWBCore
import SWBUtil
import SWBTestSupport
import SWBTaskExecution
import SwiftBuildTestSupport

@Suite
fileprivate struct CopyTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .skipHostOS(.windows))
    func copySymlinkedDirectoryTree() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("MyDirectory"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"])],
                        targets: [
                            TestAggregateTarget(
                                "Empty",
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestCopyFilesBuildPhase([TestBuildFile("MyDirectory")], destinationSubfolder: .absolute, destinationSubpath: tmpDirPath.join("out").str, onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "", originalObjectID: "", inputs: [tmpDirPath.join("out").join("MyDirectory").str], outputs: [tmpDirPath.join("out2").str])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try tester.fs.createDirectory(SRCROOT, recursive: true)
            try tester.fs.createDirectory(SRCROOT.join("MyOtherDirectory"))
            try tester.fs.write(SRCROOT.join("MyOtherDirectory").join("file.txt"), contents: "Foo")
            try tester.fs.symlink(SRCROOT.join("MyDirectory"), target: Path("MyDirectory").join("file.txt").join("..").join("..").join("MyOtherDirectory"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .host) { results in
                results.checkNoDiagnostics()
                try #expect(tester.fs.listdir(tmpDirPath.join("out").join("MyDirectory")) == ["file.txt"])
            }
        }
    }

    /// rdar://117046957: xcfilelists read by Custom Build Rules should be registered
    /// as invalidation paths so changing them triggers a new build description.
    @Test(.requireSDKs(.host), .skipHostOS(.windows))
    func buildRuleXcfilelistTrackedAsInvalidationPath() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("input.fake-custom"),
                            TestFile("inputs.xcfilelist"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "GENERATE_INFOPLIST_FILE": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "App", type: .application,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["input.fake-custom"]),
                                ],
                                buildRules: [
                                    TestBuildRule(
                                        filePattern: "*.fake-custom",
                                        script: "touch \"${SCRIPT_OUTPUT_FILE_0}\"",
                                        inputFileLists: ["$(SRCROOT)/inputs.xcfilelist"],
                                        outputs: ["$(DERIVED_FILE_DIR)/$(INPUT_FILE_BASE).out"]
                                    ),
                                ])])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try tester.fs.createDirectory(SRCROOT, recursive: true)
            try tester.fs.write(SRCROOT.join("input.fake-custom"), contents: "original\n")

            try await tester.fs.writeFileContents(SRCROOT.join("inputs.xcfilelist")) { stream in
                stream <<< ""
            }

            let xcfilelistPath = SRCROOT.join("inputs.xcfilelist")

            try await tester.checkBuildDescription(BuildParameters(configuration: "Debug"), runDestination: .host) { results in
                let invalidationPaths = results.buildDescription.invalidationPaths
                #expect(invalidationPaths.contains(xcfilelistPath), "xcfilelist used by build rule should be an invalidation path, but invalidationPaths = \(invalidationPaths)")
            }
        }
    }

    /// rdar://133321635: When a Run Script phase input is a symlink, modifying the
    /// symlink target should cause the script to rerun on incremental builds.
    @Test(.requireSDKs(.host), .skipHostOS(.windows))
    func scriptWithSymlinkedInputRerunsWhenTargetChanges() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("MyDirectory"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"])],
                        targets: [
                            TestAggregateTarget(
                                "Empty",
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestCopyFilesBuildPhase([TestBuildFile("MyDirectory")], destinationSubfolder: .absolute, destinationSubpath: tmpDirPath.join("out").str, onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "CopyScript", originalObjectID: "CopyScript", inputs: [tmpDirPath.join("out").join("MyDirectory").str], outputs: [tmpDirPath.join("out2").str])
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try tester.fs.createDirectory(SRCROOT, recursive: true)
            try tester.fs.createDirectory(SRCROOT.join("MyOtherDirectory"))
            try tester.fs.write(SRCROOT.join("MyOtherDirectory").join("file.txt"), contents: "version1")
            try tester.fs.symlink(SRCROOT.join("MyDirectory"), target: Path("MyDirectory").join("file.txt").join("..").join("..").join("MyOtherDirectory"))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .host, persistent: true) { results in
                results.checkTask(.matchRuleType("Copy")) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution")) { _ in }
                results.checkNoDiagnostics()
            }

            try await tester.checkNullBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .host, persistent: true)

            // Modify the file behind the symlink.
            try await tester.fs.writeFileContents(SRCROOT.join("MyOtherDirectory").join("file.txt"), waitForNewTimestamp: true) { $0 <<< "version2" }

            // The copy and script should both rerun because the symlink target changed.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .host, persistent: true) { results in
                results.checkTask(.matchRuleType("Copy")) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution")) { _ in }
                results.checkNoDiagnostics()
            }
        }
    }
}
