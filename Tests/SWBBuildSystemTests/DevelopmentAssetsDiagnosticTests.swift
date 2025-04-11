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
import SWBUtil
import SWBTestSupport
import SWBTaskExecution
import SWBProtocol

@Suite
fileprivate struct DevelopmentAssetsDiagnosticTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func developmentAssetsExcludeNoDirectory() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Test that specified development resources need to exist to get excluded
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage1.jpg"),
                                                    TestFile("ExampleImage2.png")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Release")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Release",
                                                                                    buildSettings: [
                                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'"
                                                                                    ])],
                                       buildPhases: [])
                ])

            let parameters = BuildParameters(action: .install, configuration: "Release")
            try await BuildOperationTester(getCore(), testProject, simulated: false).checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkNoTask(.matchRuleItem("Preview"))

                results.checkTask(.matchRuleType("ValidateDevelopmentAssets")) { task in
                    results.checkError("[targetIntegrity] One of the paths in DEVELOPMENT_ASSET_PATHS does not exist: \(tmpDirPath.str)/Preview Assets (for task: [\"ValidateDevelopmentAssets\", \"\(tmpDirPath.str)/build/aProject.build/Release/AppTarget.build\"])")
                    results.checkTaskResult(task, expected: .exit(exitStatus: .exit(1), metrics: nil))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func developmentAssetsExclude() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Test that specified development resources get excluded
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage1.jpg", path: "ExampleImage1.jpg"),
                                                    TestFile("ExampleImage2.png", path: "ExampleImage2.jpg")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Release")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Release",
                                                                                    buildSettings: [
                                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'"
                                                                                    ])],
                                       buildPhases: [TestCopyFilesBuildPhase(["ExampleImage1.jpg", "ExampleImage2.png"], destinationSubfolder: .frameworks, onlyForDeployment: false)])
                ])

            let fs = localFS
            try fs.createDirectory(Path("\(tmpDirPath.str)/Preview Assets"), recursive: true)
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage1.jpg"), contents: ByteString(""))
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage2.png"), contents: ByteString(""))

            let parameters = BuildParameters(action: .install, configuration: "Release")
            try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: fs).checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkNoTask(.matchRuleItemPattern(.contains("Preview")))
                results.checkNoTask(.matchRuleItemPattern(.contains("ExampleImage1")))
                results.checkNoTask(.matchRuleItemPattern(.contains("ExampleImage2")))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func developmentAssetsExcludeDeploymentPostprocessing() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Test that specified development resources get excluded
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage1.jpg", path: "ExampleImage1.jpg"),
                                                    TestFile("ExampleImage2.png", path: "ExampleImage2.jpg")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Debug")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Debug",
                                                                                    buildSettings: [
                                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'"
                                                                                    ])],
                                       buildPhases: [TestCopyFilesBuildPhase(["ExampleImage1.jpg", "ExampleImage2.png"], destinationSubfolder: .frameworks, onlyForDeployment: false)])
                ])

            let fs = localFS
            try fs.createDirectory(Path("\(tmpDirPath.str)/Preview Assets"), recursive: true)
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage1.jpg"), contents: ByteString(""))
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage2.png"), contents: ByteString(""))

            let parameters = BuildParameters(action: .build, configuration: "Release", overrides: ["DEPLOYMENT_POSTPROCESSING": "YES"])
            try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: fs).checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkNoTask(.matchRuleItemPattern(.contains("Preview")))
                results.checkNoTask(.matchRuleItemPattern(.contains("ExampleImage1")))
                results.checkNoTask(.matchRuleItemPattern(.contains("ExampleImage2")))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func developmentAssetsNoExcludeNotSpecified() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Test that specified development resources get not excluded
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage1.jpg", path: "ExampleImage1.jpg"),
                                                    TestFile("ExampleImage2.png", path: "ExampleImage2.jpg")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Release", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "DSTROOT": tmpDirPath.join("dstroot").str,
                ])],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Release")],
                                       buildPhases: [
                                        TestCopyFilesBuildPhase(["ExampleImage1.jpg", "ExampleImage2.png"], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                       ])
                ])

            let parameters = BuildParameters(action: .install, configuration: "Release")

            let fs = localFS
            try fs.createDirectory(Path("\(tmpDirPath.str)/Preview Assets"), recursive: true)
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage1.jpg"), contents: ByteString(""))
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage2.jpg"), contents: ByteString(""))

            try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: fs).checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkTask(.matchRuleItemPattern(.contains("ExampleImage1"))) { task in
                    #expect(task.ruleInfo.first == "Copy")
                }
                results.checkTask(.matchRuleItemPattern(.contains("ExampleImage2"))) { task in
                    #expect(task.ruleInfo.first == "Copy")
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func developmentAssetsNoExcludeDevelopment() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Test that specified development resources get not excluded
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage1.jpg", path: "ExampleImage1.jpg"),
                                                    TestFile("ExampleImage2.png", path: "ExampleImage2.jpg")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Debug")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Debug",
                                                                                    buildSettings: [
                                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'"
                                                                                    ])],
                                       buildPhases: [
                                        TestCopyFilesBuildPhase(["ExampleImage1.jpg", "ExampleImage2.png"], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                       ])
                ])

            let parameters = BuildParameters(action: .build, configuration: "Debug")

            let fs = localFS
            try fs.createDirectory(Path("\(tmpDirPath.str)/Preview Assets"), recursive: true)
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage1.jpg"), contents: ByteString(""))
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage2.jpg"), contents: ByteString(""))

            try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: fs).checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkTask(.matchRuleItemPattern(.contains("ExampleImage1"))) { task in
                    #expect(task.ruleInfo.first == "Copy")
                }
                results.checkTask(.matchRuleItemPattern(.contains("ExampleImage2"))) { task in
                    #expect(task.ruleInfo.first == "Copy")
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func developmentAssetsFileRemovedRebuild() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Test that errors are emitted if files get removed during null rebuilds
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup("AppTarget",
                                     children: [ TestGroup("Preview Assets") ]),
                buildConfigurations: [TestBuildConfiguration("Debug")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Debug",
                                                                                    buildSettings: [
                                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'"
                                                                                    ])])
                ])

            let parameters = BuildParameters(action: .install, configuration: "Debug")

            let fs = localFS
            let developmentAssetsDirectoryPath = Path("\(tmpDirPath.str)/Preview Assets")
            try fs.createDirectory(developmentAssetsDirectoryPath, recursive: true)
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: fs)

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                // we don't expect errors because the specified directory exists
                results.checkNoDiagnostics()
            }

            // removing the directory should emit the error, even it nothing else changed
            try fs.removeDirectory(developmentAssetsDirectoryPath)
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkError("[targetIntegrity] One of the paths in DEVELOPMENT_ASSET_PATHS does not exist: \(tmpDirPath.str)/Preview Assets (for task: [\"ValidateDevelopmentAssets\", \"\(tmpDirPath.str)/build/aProject.build/Debug/AppTarget.build\"])")
                results.checkNoDiagnostics()
            }
        }
    }

    /// Tests that the diagnostic gets disambiguated with the project path in the case of multiple projects with the same name in the workspace.
    @Test(.requireSDKs(.macOS))
    func developmentAssetsExcludeNoDirectoryTwoProjects() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage1.jpg"),
                                                    TestFile("ExampleImage2.png")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Release")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Release",
                                                                                    buildSettings: [
                                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'"
                                                                                    ])],
                                       buildPhases: [])
                ])

            let testProject2 = TestProject(
                "aProject",
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage3.jpg"),
                                                    TestFile("ExampleImage4.png")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Release")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Release",
                                                                                    buildSettings: [
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'"
                                                                                    ])],
                                       buildPhases: [])
                ])

            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject, testProject2])
            let parameters = BuildParameters(action: .install, configuration: "Release")
            try await BuildOperationTester(getCore(), testWorkspace, simulated: false).checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkNoTask(.matchRuleItem("Preview"))

                results.checkError("[targetIntegrity] One of the paths in DEVELOPMENT_ASSET_PATHS does not exist: \(tmpDirPath.str)/aProject/Preview Assets (for task: [\"ValidateDevelopmentAssets\", \"\(tmpDirPath.str)/aProject/build/aProject.build/Release/AppTarget.build\"])")
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func developmentAssetsOverriddenSRCROOT() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Some environments override SRCROOT but that shouldn't interfere with relative paths in DEVELOPMENT_ASSET_PATHS since they are based in PROJECT_DIR
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup("AppTarget",
                                     children: [
                                        TestGroup("Preview Assets",
                                                  children: [
                                                    TestFile("ExampleImage1.jpg", path: "ExampleImage1.jpg"),
                                                    TestFile("ExampleImage2.png", path: "ExampleImage2.jpg")
                                                  ])
                                     ]),
                buildConfigurations: [TestBuildConfiguration("Release")],
                targets: [
                    TestStandardTarget("AppTarget",
                                       type: .commandLineTool,
                                       buildConfigurations: [TestBuildConfiguration("Release",
                                                                                    buildSettings: [
                                                                                        "CODE_SIGNING_ALLOWED": "NO",
                                                                                        "DEVELOPMENT_ASSET_PATHS": "'Preview Assets'",
                                                                                        "SRCROOT": "Sources"
                                                                                    ])],
                                       buildPhases: [TestCopyFilesBuildPhase(["ExampleImage1.jpg", "ExampleImage2.png"], destinationSubfolder: .frameworks, onlyForDeployment: false)])
                ])

            let fs = localFS
            try fs.createDirectory(Path("\(tmpDirPath.str)/Preview Assets"), recursive: true)
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage1.jpg"), contents: ByteString(""))
            try fs.write(Path("\(tmpDirPath.str)/Preview Assets/ExampleImage2.png"), contents: ByteString(""))

            let parameters = BuildParameters(action: .install, configuration: "Release")
            try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: fs).checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkNoTask(.matchRuleItemPattern(.contains("Preview")))
                results.checkNoTask(.matchRuleItemPattern(.contains("ExampleImage1")))
                results.checkNoTask(.matchRuleItemPattern(.contains("ExampleImage2")))

                results.checkNoDiagnostics()
            }
        }
    }
}
