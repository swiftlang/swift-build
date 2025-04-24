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

import SWBTestSupport
import SWBUtil
import SWBCore

@Suite
fileprivate struct SceneKitBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func sceneKitTools() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("A.dae"),
                        TestFile("B.dae"),
                        TestFile("C.DAE"), // test that uppercase extensions work too
                        TestFile("D.scnassets"),
                        TestFile("E.scncache"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget("App",
                                       type: .application,
                                       buildPhases: [
                        TestResourcesBuildPhase([
                            TestBuildFile("A.dae", decompress: false),
                            TestBuildFile("B.dae", decompress: true),
                            TestBuildFile("C.DAE", decompress: false),
                            TestBuildFile("D.scnassets"),
                            TestBuildFile("E.scncache"),
                        ]),
                    ]),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try tester.fs.writeDAE(Path(SRCROOT).join("Sources").join("A.dae"))
            try tester.fs.writeDAE(Path(SRCROOT).join("Sources").join("B.dae"))
            try tester.fs.writeDAE(Path(SRCROOT).join("Sources").join("C.DAE"))
            try tester.fs.createDirectory(Path(SRCROOT).join("Sources").join("D.scnassets"))
            try tester.fs.createDirectory(Path(SRCROOT).join("Sources").join("E.scncache"))

            // Write a .scn file into the .scnassets bundle to influence copySceneKitAssets to run scntool under the hood.
            try await withTemporaryDirectory(fs: tester.fs) { tmpDir in
                let dae = tmpDir.join("temp.dae")
                try tester.fs.writeDAE(dae)
                _ = try await runHostProcess(["scntool", "--convert", dae.str, "--format", "scn", "--output", Path(SRCROOT).join("Sources").join("D.scnassets").join("scene.scn").str])
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("Process"), .matchRuleItemBasename("A.dae")) { task in
                    task.checkRuleInfo(["Process", "SceneKit", "document", "\(SRCROOT)/Sources/A.dae"])
                    task.checkCommandLineContains([core.developerPath.path.join("usr").join("bin").join("scntool").str, "--compress", "\(SRCROOT)/Sources/A.dae"])
                    task.checkEnvironment([:], exact: true)
                }
                results.checkTask(.matchRuleType("Process"), .matchRuleItemBasename("B.dae")) { task in
                    task.checkRuleInfo(["Process", "SceneKit", "document", "\(SRCROOT)/Sources/B.dae"])
                    task.checkCommandLineContains([core.developerPath.path.join("usr").join("bin").join("scntool").str, "--decompress", "\(SRCROOT)/Sources/B.dae"])
                    task.checkEnvironment([:], exact: true)
                }
                results.checkTask(.matchRuleType("Process"), .matchRuleItemBasename("C.DAE")) { task in
                    task.checkRuleInfo(["Process", "SceneKit", "document", "\(SRCROOT)/Sources/C.DAE"])
                    task.checkCommandLineContains([core.developerPath.path.join("usr").join("bin").join("scntool").str, "--compress", "\(SRCROOT)/Sources/C.DAE", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/C.dae"])
                    task.checkEnvironment([:], exact: true)
                }
                results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("D.scnassets")) { task in
                    task.checkRuleInfo(["Copy", "SceneKit", "assets", "\(SRCROOT)/Sources/D.scnassets"])
                    task.checkCommandLineContainsUninterrupted(["\(core.developerPath.path.str)/usr/bin/copySceneKitAssets", "\(SRCROOT)/Sources/D.scnassets", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/D.scnassets", "--target-platform=macosx", "--target-version=\(core.loadSDK(.macOS).defaultDeploymentTarget)"])
                    task.checkCommandLineContainsUninterrupted([ "--target-build-dir=\(SRCROOT)/build/Debug", "--resources-folder-path=App.app/Contents/Resources"])
                    task.checkEnvironment([:], exact: true)
                }
                results.checkTask(.matchRuleType("Compile"), .matchRuleItemBasename("E.scncache")) { task in
                    task.checkRuleInfo(["Compile", "SceneKit", "Shaders", "\(SRCROOT)/Sources/E.scncache"])
                    task.checkCommandLineContainsUninterrupted(["\(core.developerPath.path.str)/usr/bin/compileSceneKitShaders", "\(SRCROOT)/Sources/E.scncache", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/scenekit.metallib", "--target-platform=macosx", "--target-version=\(core.loadSDK(.macOS).defaultDeploymentTarget)"])
                    task.checkCommandLineContainsUninterrupted(["--target-build-dir=\(SRCROOT)/build/Debug", "--resources-folder-path=App.app/Contents/Resources", "--intermediate-dir=\(SRCROOT)/build/aProject.build/Debug/App.build"])
                    task.checkEnvironment([:], exact: true)
                }
                results.checkNoDiagnostics()
            }
        }
    }
}
