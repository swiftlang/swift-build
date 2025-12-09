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
}
