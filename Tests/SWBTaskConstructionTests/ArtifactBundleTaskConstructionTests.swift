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
import Foundation

import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil
import SWBTaskConstruction

@Suite
fileprivate struct ArtifactBundleTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func buildSettingsTripleCondition() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles",
                    path: "Sources",
                    children: [
                        TestFile("SourceFile.swift")
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "LIBTOOL": libtoolPath.str,
                            "SWIFT_ACTIVE_COMPILATION_CONDITIONS[__normalized_unversioned_triple=arm64-apple-macos]": "CONDITION_ACTIVE",
                        ]
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "target",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.swift"])
                        ]
                    )
                ]
            )
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOSAppleSilicon) { results -> Void in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-DCONDITION_ACTIVE"])
                }
            }

            await tester.checkBuild(runDestination: .macOSIntel) { results -> Void in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineDoesNotContain("-DCONDITION_ACTIVE")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func artifactBundleWithStaticLibrary() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles",
                    path: "Sources",
                    children: [
                        TestFile("s.swift"),
                        TestFile("c.c"),
                        TestFile("MyLibrary.artifactbundle"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                        ]
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "Framework",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["s.swift", "c.c"]),
                            TestFrameworksBuildPhase(["MyLibrary.artifactbundle"]),
                        ]
                    )
                ]
            )
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            try fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try fs.write(Path(SRCROOT).join("Sources/s.swift"), contents: "print(\"Hello\")")
            try fs.write(Path(SRCROOT).join("Sources/c.c"), contents: "void f(void) {}")

            let artifactBundlePath = Path(SRCROOT).join("Sources/MyLibrary.artifactbundle")
            try fs.createDirectory(artifactBundlePath, recursive: true)
            let arm64VariantPath = artifactBundlePath.join("macos-arm64")
            try fs.createDirectory(arm64VariantPath.join("include"), recursive: true)
            try fs.write(arm64VariantPath.join("libMyLibrary.a"), contents: "")
            try fs.write(arm64VariantPath.join("include/MyLibrary.h"), contents: "void bar(void);")
            try fs.write(arm64VariantPath.join("include/module.modulemap"), contents: "module MyLibrary { header \"MyLibrary.h\" }")
            let x86VariantPath = artifactBundlePath.join("macos-x86_64")
            try fs.createDirectory(x86VariantPath.join("include"), recursive: true)
            try fs.write(x86VariantPath.join("libMyLibrary.a"), contents: "")
            try fs.write(x86VariantPath.join("include/MyLibrary.h"), contents: "void bar(void);")
            try fs.write(x86VariantPath.join("include/module.modulemap"), contents: "module MyLibrary { header \"MyLibrary.h\" }")
            let infoJSONContent = """
                {
                  "schemaVersion": "1.2",
                  "artifacts": {
                    "MyLibrary": {
                      "type": "staticLibrary",
                      "version": "1.0.0",
                      "variants": [
                        {
                          "path": "macos-arm64/libMyLibrary.a",
                          "supportedTriples": ["arm64-apple-macos"],
                          "staticLibraryMetadata": {
                            "headerPaths": ["macos-arm64/include"],
                            "moduleMapPath": "macos-arm64/include/module.modulemap"
                          }
                        },
                        {
                          "path": "macos-x86_64/libMyLibrary.a",
                          "supportedTriples": ["x86_64-apple-macos"],
                          "staticLibraryMetadata": {
                            "headerPaths": ["macos-x86_64/include"],
                            "moduleMapPath": "macos-x86_64/include/module.modulemap"
                          }
                        }
                      ]
                    }
                  }
                }
                """
            try fs.write(artifactBundlePath.join("info.json"), contents: ByteString(encodingAsUTF8: infoJSONContent))

            await tester.checkBuild(runDestination: .macOSAppleSilicon, fs: fs) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        "-Xcc", "-fmodule-map-file=\(SRCROOT)/Sources/MyLibrary.artifactbundle/macos-arm64/include/module.modulemap",
                    ])
                    task.checkCommandLineContains([
                        "-Xcc", "-I\(SRCROOT)/Sources/MyLibrary.artifactbundle/macos-arm64/include",
                    ])
                }

                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains([
                        "-fmodule-map-file=\(SRCROOT)/Sources/MyLibrary.artifactbundle/macos-arm64/include/module.modulemap"
                    ])
                    task.checkCommandLineContains([
                        "-I\(SRCROOT)/Sources/MyLibrary.artifactbundle/macos-arm64/include"
                    ])
                }

                results.checkTask(.matchRuleType("Ld")) { task in
                    task.checkCommandLineContains(["\(SRCROOT)/Sources/MyLibrary.artifactbundle/macos-arm64/libMyLibrary.a"])
                }
            }
        }
    }
}
