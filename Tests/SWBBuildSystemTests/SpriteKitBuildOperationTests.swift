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

import Testing
import SwiftBuildTestSupport
import SWBCore

@Suite
fileprivate struct SpriteKitBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func spriteKitTools() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("assets.atlas"),
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
                            TestBuildFile("assets.atlas"),
                        ]),
                    ]),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try tester.fs.createDirectory(Path(SRCROOT).join("Sources").join("assets.atlas"))
            try tester.fs.writeImage(Path(SRCROOT).join("Sources").join("assets.atlas").join("foo.png"), width: 16, height: 16)

            try await tester.checkBuild(runDestination: .macOS) { results in
                try results.checkTask(.matchRuleType("GenerateTextureAtlas")) { task in
                    task.checkRuleInfo(["GenerateTextureAtlas", "\(SRCROOT)/build/Debug/App.app/Contents/Resources/assets.atlasc", "\(SRCROOT)/Sources/assets.atlas"])
                    task.checkCommandLine(["\(core.developerPath.path.str)/usr/bin/TextureAtlas", "\(SRCROOT)/Sources/assets.atlas", "\(SRCROOT)/build/Debug/App.app/Contents/Resources"])
                    task.checkEnvironment([:], exact: true)

                    try results.checkPropertyListContents(Path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/assets.atlasc/assets.plist")) { plist in
                        #expect(plist.dictValue?["format"] == "APPL")
                        #expect(plist.dictValue?["version"] == 1)
                        #expect(plist.dictValue?["images"]?.arrayValue?.count == 1)
                    }

                    results.checkFileExists(Path("\(SRCROOT)/build/Debug/App.app/Contents/Resources/assets.atlasc/assets.1.png"))
                }
                results.checkNoDiagnostics()
            }
        }
    }
}
