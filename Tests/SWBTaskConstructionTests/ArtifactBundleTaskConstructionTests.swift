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
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.swift"),
                    ]),
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
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "target",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.swift"]),
                        ]
                    )
                ])
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
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("s.swift"),
                        TestFile("c.c"),
                        TestFile("MyLibrary.artifactbundle"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                        ]),
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
                ])
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
                        "-Xcc", "-fmodule-map-file=\(SRCROOT)/Sources/MyLibrary.artifactbundle/macos-arm64/include/module.modulemap"
                    ])
                    task.checkCommandLineContains([
                        "-Xcc", "-I\(SRCROOT)/Sources/MyLibrary.artifactbundle/macos-arm64/include"
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

    @Test(.requireSDKs(.macOS))
    func artifactBundleWithWindowsDLLs() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                        TestFile("MyDLLs.artifactbundle"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            // Force a Windows triple so the x86_64 variant is selected.
                            "SWIFT_TARGET_TRIPLE": "x86_64-unknown-windows-msvc",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase(["MyDLLs.artifactbundle"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            try fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try fs.write(Path(SRCROOT).join("Sources/main.swift"), contents: "")

            let artifactBundlePath = Path(SRCROOT).join("Sources/MyDLLs.artifactbundle")
            try fs.createDirectory(artifactBundlePath.join("windows-x86_64"), recursive: true)
            try fs.write(artifactBundlePath.join("windows-x86_64/foo.dll"), contents: "")
            try fs.createDirectory(artifactBundlePath.join("windows-arm64"), recursive: true)
            try fs.write(artifactBundlePath.join("windows-arm64/foo.dll"), contents: "")
            let infoJSONContent = """
            {
              "schemaVersion": "1.0",
              "artifacts": {
                "foo": {
                  "type": "experimentalWindowsDLL",
                  "version": "1.0.0",
                  "variants": [
                    {
                      "path": "windows-x86_64/foo.dll",
                      "supportedTriples": ["x86_64-unknown-windows-msvc"]
                    },
                    {
                      "path": "windows-arm64/foo.dll",
                      "supportedTriples": ["aarch64-unknown-windows-msvc"]
                    }
                  ]
                }
              }
            }
            """
            try fs.write(artifactBundlePath.join("info.json"), contents: ByteString(encodingAsUTF8: infoJSONContent))

            await tester.checkBuild(runDestination: .macOSAppleSilicon, fs: fs) { results in
                results.checkNoDiagnostics()

                // The x86_64 variant should be copied; the arm64 variant should not.
                results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("foo.dll")) { task in
                    task.checkCommandLineContains([
                        "\(SRCROOT)/Sources/MyDLLs.artifactbundle/windows-x86_64/foo.dll"
                    ])
                    task.checkCommandLineDoesNotContain("\(SRCROOT)/Sources/MyDLLs.artifactbundle/windows-arm64/foo.dll")
                }
            }
        }
    }

    @Test(.requireSDKs(.windows))
    func artifactBundleWithWindowsDLLsCopiedOnWindows() async throws {
        // Integration test that runs natively on Windows CI. Unlike the macOS-based
        // tests above, this uses the real Windows SDK triple without any override, so
        // it exercises the full task-construction path including SDK-derived settings.
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                        TestFile("MyDLLs.artifactbundle"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase(["MyDLLs.artifactbundle"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            try fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try fs.write(Path(SRCROOT).join("Sources/main.swift"), contents: "")

            let artifactBundlePath = Path(SRCROOT).join("Sources/MyDLLs.artifactbundle")
            try fs.createDirectory(artifactBundlePath.join("windows-x86_64"), recursive: true)
            try fs.write(artifactBundlePath.join("windows-x86_64/foo.dll"), contents: "")
            try fs.createDirectory(artifactBundlePath.join("windows-aarch64"), recursive: true)
            try fs.write(artifactBundlePath.join("windows-aarch64/foo.dll"), contents: "")
            let infoJSONContent = """
            {
              "schemaVersion": "1.0",
              "artifacts": {
                "foo": {
                  "type": "experimentalWindowsDLL",
                  "version": "1.0.0",
                  "variants": [
                    {
                      "path": "windows-x86_64/foo.dll",
                      "supportedTriples": ["x86_64-unknown-windows-msvc"]
                    },
                    {
                      "path": "windows-aarch64/foo.dll",
                      "supportedTriples": ["aarch64-unknown-windows-msvc"]
                    }
                  ]
                }
              }
            }
            """
            try fs.write(artifactBundlePath.join("info.json"), contents: ByteString(encodingAsUTF8: infoJSONContent))

            await tester.checkBuild(runDestination: .host, fs: fs) { results in
                results.checkNoDiagnostics()
                // The variant matching the host Windows triple should be copied.
                results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("foo.dll")) { task in
                    #expect(task.commandLineAsStrings.contains { $0.contains("MyDLLs.artifactbundle") })
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func artifactBundleWithWindowsDLLsSkippedForStaticLibrary() async throws {
        // Static library targets must not generate DLL copy tasks — they don't execute
        // directly and multiple static libs referencing the same artifact bundle would
        // otherwise produce conflicting copy tasks to the shared products directory.
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("lib.c"),
                        TestFile("MyDLLs.artifactbundle"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "LIBTOOL": libtoolPath.str,
                            "SWIFT_TARGET_TRIPLE": "x86_64-unknown-windows-msvc",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "MyLib",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["lib.c"]),
                            TestFrameworksBuildPhase(["MyDLLs.artifactbundle"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            try fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try fs.write(Path(SRCROOT).join("Sources/lib.c"), contents: "void f(void) {}")

            let artifactBundlePath = Path(SRCROOT).join("Sources/MyDLLs.artifactbundle")
            try fs.createDirectory(artifactBundlePath.join("windows-x86_64"), recursive: true)
            try fs.write(artifactBundlePath.join("windows-x86_64/foo.dll"), contents: "")
            let infoJSONContent = """
            {
              "schemaVersion": "1.0",
              "artifacts": {
                "foo": {
                  "type": "experimentalWindowsDLL",
                  "version": "1.0.0",
                  "variants": [
                    {
                      "path": "windows-x86_64/foo.dll",
                      "supportedTriples": ["x86_64-unknown-windows-msvc"]
                    }
                  ]
                }
              }
            }
            """
            try fs.write(artifactBundlePath.join("info.json"), contents: ByteString(encodingAsUTF8: infoJSONContent))

            await tester.checkBuild(runDestination: .macOSAppleSilicon, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkNoTask(.matchRuleType("Copy"), .matchRuleItemBasename("foo.dll"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func artifactBundleWithWindowsDLLsNoMatchWarning() async throws {
        // When no variant matches the current triple a warning should be emitted and
        // no copy task should be generated.
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                        TestFile("MyDLLs.artifactbundle"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            // A triple that matches neither variant.
                            "SWIFT_TARGET_TRIPLE": "riscv64-unknown-linux-gnu",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase(["MyDLLs.artifactbundle"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            try fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try fs.write(Path(SRCROOT).join("Sources/main.swift"), contents: "")

            let artifactBundlePath = Path(SRCROOT).join("Sources/MyDLLs.artifactbundle")
            try fs.createDirectory(artifactBundlePath.join("windows-x86_64"), recursive: true)
            try fs.write(artifactBundlePath.join("windows-x86_64/foo.dll"), contents: "")
            let infoJSONContent = """
            {
              "schemaVersion": "1.0",
              "artifacts": {
                "foo": {
                  "type": "experimentalWindowsDLL",
                  "version": "1.0.0",
                  "variants": [
                    {
                      "path": "windows-x86_64/foo.dll",
                      "supportedTriples": ["x86_64-unknown-windows-msvc"]
                    }
                  ]
                }
              }
            }
            """
            try fs.write(artifactBundlePath.join("info.json"), contents: ByteString(encodingAsUTF8: infoJSONContent))

            await tester.checkBuild(runDestination: .macOSAppleSilicon, fs: fs) { results in
                results.checkWarning(.contains("ignoring 'foo' because the artifact bundle did not contain a matching variant"))
                results.checkNoTask(.matchRuleType("Copy"), .matchRuleItemBasename("foo.dll"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func artifactBundleInfoPropagatesThroughPackageProductTarget() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("cli.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "CLI",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["cli.swift"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("PackageProduct")),
                            ]),
                        ],
                        dependencies: ["PackageProduct"]),
                ])
            let testPackage = try await TestPackageProject(
                "Package",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "PackageFiles", path: "Sources",
                    children: [
                        TestFile("lib.c"),
                        TestFile("MyLibrary.artifactbundle"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "LIBTOOL": libtoolPath.str,
                        ]),
                ],
                targets: [
                    TestPackageProductTarget(
                        "PackageProduct",
                        frameworksBuildPhase: TestFrameworksBuildPhase([
                            TestBuildFile(.target("LibTarget")),
                        ]),
                        dependencies: ["LibTarget"]),
                    TestStandardTarget(
                        "LibTarget",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["lib.c"]),
                            TestFrameworksBuildPhase(["MyLibrary.artifactbundle"]),
                        ]),
                ])
            let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject, testPackage])
            let tester = try await TaskConstructionTester(getCore(), testWorkspace)
            let packageSrcRoot = tester.workspace.projects[1].sourceRoot.str
            let projectSrcRoot = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            try fs.createDirectory(Path(packageSrcRoot).join("Sources"), recursive: true)
            try fs.write(Path(packageSrcRoot).join("Sources/lib.c"), contents: "void f(void) {}")

            try fs.createDirectory(Path(projectSrcRoot).join("Sources"), recursive: true)
            try fs.write(Path(projectSrcRoot).join("Sources/cli.swift"), contents: "func g() {}")

            let artifactBundlePath = Path(packageSrcRoot).join("Sources/MyLibrary.artifactbundle")
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
                results.checkTarget("CLI") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains([
                            "-Xcc", "-fmodule-map-file=\(packageSrcRoot)/Sources/MyLibrary.artifactbundle/macos-arm64/include/module.modulemap"
                        ])
                        task.checkCommandLineContains([
                            "-Xcc", "-I\(packageSrcRoot)/Sources/MyLibrary.artifactbundle/macos-arm64/include"
                        ])
                    }
                }
            }
        }
    }
}
