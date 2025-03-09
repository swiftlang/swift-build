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

import struct Foundation.Data
import struct Foundation.UUID

import Testing

import SWBUtil
import enum SWBProtocol.ExternalToolResult
import SWBCore
import SWBTaskConstruction
import SWBTestSupport

// A mock xcstringstool to respond to the compile --dry-run request.
private final class MockXCStringsTool: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
    /// Maps input files to output files.
    let relativeOutputFilePaths: [String: [String]]
    let requiredCommandLine: [String]?

    init(relativeOutputFilePaths: [String : [String]], requiredCommandLine: [String]?) {
        self.relativeOutputFilePaths = relativeOutputFilePaths
        self.requiredCommandLine = requiredCommandLine
    }

    override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
        switch commandLine.first.map(Path.init)?.basename {
        case "xcstringstool":
            break
        default:
            return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
        }

        // This better be just a dry run!
        guard commandLine.contains("--dry-run") else {
            throw StubError.error("Tried to run xcstringstool outside of dry run mode during build planning.")
        }

        if let requiredCommandLine {
            guard commandLine == requiredCommandLine else {
                // Get a nice diff printout.
                XCTAssertEqualSequences(commandLine, requiredCommandLine)
                throw StubError.error("Unexpected command line: \(commandLine)")
            }
        }

        // Last arg is input.
        guard let inputPath = commandLine.last.map(Path.init) else {
            throw StubError.error("Couldn't find input file in command line.")
        }

        // Second to last arg is output directory.
        guard let outputDir = commandLine[safe: commandLine.endIndex - 2].map(Path.init) else {
            throw StubError.error("Couldn't find output directory in command line.")
        }

        // Create full list of output paths.
        var outputPaths = relativeOutputFilePaths[inputPath.str]?.map { relativePath in
            return outputDir.join(relativePath)
        } ?? []

        // Grab requested languages from command line.
        var requestedLangs = Set<String>()
        var cmdLine = commandLine[commandLine.startIndex...] // Create Array Slice
        while let index = cmdLine.firstIndex(of: "-l"), cmdLine.indices.contains(index + 1) {
            let lang = cmdLine[index + 1]
            let (inserted, _) = requestedLangs.insert(lang)
            if !inserted {
                throw StubError.error("Passed -l \(lang) more than once. Sounds like a bug.")
            }
            cmdLine = cmdLine[(index + 1)...]
        }

        // No requested languages means all languages.
        // Otherwise we filter our outputs here as a way of testing that installloc properly passes -l for the language.
        if !requestedLangs.isEmpty {
            outputPaths = outputPaths.filter { path in
                for lang in requestedLangs where path.str.contains("\(lang).lproj") {
                    return true
                }
                return false
            }
        }

        // Return newline separated output paths, just as we expect xcstringstool to do.
        return .result(status: .exit(0), stdout: Data(outputPaths.map(\.str).joined(separator: "\n").utf8), stderr: .init())
    }
}

@Suite
fileprivate struct XCStringsTaskConstructionTests: CoreBasedTests {
    // Baseline of a project not using xcstrings files, but with manual strings files instead.
    @Test(.requireSDKs(.macOS))
    func withoutXCStrings() async throws {
        let testProject = try await TestProject(
            "legacyProject",
            groupTree: TestGroup(
                "LegacyProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Localizable.strings", regionVariantName: "de"),
                    ]),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.strings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/legacyProject/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.strings", "/tmp/Test/legacyProject/Sources/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/legacyProject/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.strings", "/tmp/Test/legacyProject/Sources/de.lproj/Localizable.strings"])) { _ in }
            }

            results.checkNoTask(.matchRuleType("CompileXCStrings"))
        }
    }

    // Simple case of a single xcstrings file that can be compiled as-is without syncing.
    @Test(.requireSDKs(.macOS))
    func basicCompile() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"), // Note: xcstrings don't belong in lprojs / variant groups.
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains English and German strings, and that they have variations.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : [ // input
            "en.lproj/Localizable.strings",
            "en.lproj/Localizable.stringsdict",
            "de.lproj/Localizable.strings",
            "de.lproj/Localizable.stringsdict",
                                                                                                                             ]], requiredCommandLine: [
                                                                                                                                "xcstringstool", "compile",
                                                                                                                                "--dry-run",
                                                                                                                                "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build",
                                                                                                                                "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                                                                                                                             ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // There should not be any generic CpResource tasks because that would indicate that the xcstrings file is just being copied as is.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // We need a task to compile the XCStrings into .strings and .stringsdict files.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { task in

                    // Input is source xcstrings file.
                    task.checkInputs(contain: [.path("/tmp/Test/Project/Sources/Localizable.xcstrings")])

                    // Outputs are .strings and .stringsdicts in the TempResourcesDir.
                    task.checkOutputs([
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.strings"),
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.stringsdict"),
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.strings"),
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.stringsdict"),
                    ])

                    task.checkCommandLine([
                        "xcstringstool", "compile",
                        "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build",
                        "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                    ])
                }


                // Then we need the standard CopyStringsFile tasks to have the compiled .strings/dict as input.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.stringsdict"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.stringsdict"])) { _ in }

                // And these should be the only CopyStringsFile tasks.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // Simple case of a single xcstrings file that can be compiled as-is without syncing.
    @Test(.requireSDKs(.macOS))
    func noOutputs() async throws {

        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"), // Note: In this test we pretend this file doesn't contain any strings that need built.
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file doesn't contain any strings needing to be built.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : []], requiredCommandLine: [
            "xcstringstool", "compile",
            "--dry-run",
            "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build",
            "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
        ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // There should not be any generic CpResource tasks because that would indicate that the xcstrings file is just being copied as is.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // No tasks need to be generated for this xcstrings because there are no strings to be built.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXCStrings"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // rdar://103440232 (Multiple commands produce Gate UncompiledXCStrings)
    @Test(.requireSDKs(.macOS))
    func emptyFileAddedToMultipleTargets() async throws {

        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"), // Note: In this test we pretend this file doesn't contain any strings that need built.
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                ),
                TestStandardTarget(
                    "MyFramework_Clone",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file doesn't contain any strings needing to be built.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : []], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        let framework1 = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug"), target: tester.workspace.projects[0].targets[0])
        let framework2 = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug"), target: tester.workspace.projects[0].targets[1])
        let buildRequest = BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: [framework1, framework2], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, clientDelegate: xcstringsTool) { results in
            // This situation caused a multiple commands produce error for the virtual output nodes of the UncompiledXCStrings Gates.
            // The nodes should be unique, at least by target/file pair.
            results.checkNoDiagnostics()
        }
    }

    // An xcstrings file in Copy Files rather than a Resources build phase should just be copied.
    // (Assuming APPLY_RULES_IN_COPY_FILES has not been set.)
    @Test(.requireSDKs(.macOS))
    func inCopyFiles() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"), // Note: xcstrings don't belong in lprojs / variant groups.
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestCopyFilesBuildPhase([
                            "Localizable.xcstrings",
                        ], destinationSubfolder: .resources, onlyForDeployment: false)
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // xcstringstool shouldn't be called.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [:], requiredCommandLine: ["don't call me"])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // Just copy it.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/Localizable.xcstrings", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }

                // Don't do anything else with it.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXCStrings"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // When multiple xcstrings files are present, they should be compiled separately, not grouped.
    @Test(.requireSDKs(.macOS))
    func compileMultipleXCStrings() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"),
                    TestFile("CustomTable.xcstrings"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings",
                            "CustomTable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings files contain English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
            "/tmp/Test/Project/Sources/CustomTable.xcstrings" : [
                "en.lproj/CustomTable.strings",
                "de.lproj/CustomTable.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // We should have two separate XCStrings tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/CustomTable.xcstrings"])) { _ in }

                // We should then have 4 CopyStringsFile tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/CustomTable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/CustomTable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/CustomTable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/CustomTable.strings"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // Having .xcstrings and .strings/dict in the same project is okay as long as there is no table overlap.
    @Test(.requireSDKs(.macOS))
    func compileMixedProject() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"),
                    TestVariantGroup("CustomTable.strings", children: [
                        TestFile("en.lproj/CustomTable.strings", regionVariantName: "en"),
                        TestFile("de.lproj/CustomTable.strings", regionVariantName: "de"),
                    ]),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings",
                            "CustomTable.strings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings files contain English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // We should have 1 XCStrings task and 4 CopyStringsFile tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXCStrings"))

                // We should then have 4 CopyStringsFile tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/CustomTable.strings", "/tmp/Test/Project/Sources/en.lproj/CustomTable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/CustomTable.strings", "/tmp/Test/Project/Sources/de.lproj/CustomTable.strings"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // .xcstrings and .strings/dict files in the same project are not allowed to have table overlap.
    @Test(.requireSDKs(.macOS))
    func compileMixedProjectWithTableOverlap() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Localizable.strings", regionVariantName: "de"),
                    ]),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings",
                            "Localizable.strings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings files contain English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            // This is not a supported configuration.
            results.checkError(.and(.contains("Localizable.xcstrings cannot co-exist with other .strings or .stringsdict tables with the same name."), .prefix("/tmp/Test/Project/Sources/Localizable.xcstrings")))
        }
    }

    // rdar://108866595 (15A158: Xcode should have warned me I have two Localizable.xcstrings files for a target)
    @Test(.requireSDKs(.macOS))
    func compileWithTableOverlap() async throws {

        let catalog1 = TestFile("Localizable.xcstrings", guid: UUID().uuidString)
        let catalog2 = TestFile("Localizable.xcstrings", guid: UUID().uuidString)

        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    catalog1,
                    TestGroup("Subdir", path: "Subdir", children: [
                        catalog2
                    ]),
                    TestFile("Other.xcstrings")
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Other.xcstrings",
                            TestBuildFile(catalog1),
                            TestBuildFile(catalog2),
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings files contain English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
            "/tmp/Test/Project/Sources/Subdir/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
            "/tmp/Test/Project/Sources/Other.xcstrings" : [
                "en.lproj/Other.strings",
                "de.lproj/Other.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            // This is not a supported configuration.
            results.checkError(.contains("Cannot have multiple Localizable.xcstrings files in same target."))
        }
    }

    @Test(.requireSDKs(.macOS))
    func compileWithSameNameTablesInSeparateTargets() async throws {

        let catalog1 = TestFile("Localizable.xcstrings", guid: UUID().uuidString)
        let catalog2 = TestFile("Localizable.xcstrings", guid: UUID().uuidString)

        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestGroup("Target1", path: "Target1", children: [
                        TestFile("Target1.swift"),
                        catalog1,
                    ]),
                    TestGroup("Target2", path: "Target2", children: [
                        TestFile("Target2.swift"),
                        catalog2,
                    ])
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "Target1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Target1.swift"
                        ]),
                        TestResourcesBuildPhase([
                            TestBuildFile(catalog1),
                        ])
                    ]
                ),
                TestStandardTarget(
                    "Target2",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Target2.swift"
                        ]),
                        TestResourcesBuildPhase([
                            TestBuildFile(catalog2),
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings files contain English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/Target1/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
            "/tmp/Test/Project/Sources/Target2/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        let target1 = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug"), target: tester.workspace.projects[0].targets[0])
        let target2 = BuildRequest.BuildTargetInfo(parameters: BuildParameters(configuration: "Debug"), target: tester.workspace.projects[0].targets[1])
        let buildRequest = BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: [target1, target2], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, clientDelegate: xcstringsTool) { results in
            // This is a perfectly supported configuration.
            results.checkNoDiagnostics()

            results.checkTarget("Target1") { target in
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileXCStrings"))
            }

            results.checkTarget("Target2") { target in
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileXCStrings"))
            }
        }
    }

    // String Catalogs don't belong in lproj directories.
    @Test(.requireSDKs(.macOS))
    func compileWithinLproj() async throws {

        let catalog = TestFile("en.lproj/Localizable.xcstrings")

        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    catalog,
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            TestBuildFile(catalog),
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/en.lproj/Localizable.xcstrings" : [
                "en.lproj/Localizable.strings",
                "de.lproj/Localizable.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            // This is not a supported configuration.
            results.checkError(.contains("Localizable.xcstrings should not be inside an lproj directory."))
        }
    }

    // xcstrings files also need compiled during installloc builds.
    @Test(.requireSDKs(.iOS))
    func compileDuringInstallloc() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"), // Note: xcstrings don't belong in lprojs / variant groups.
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT" : "iphoneos",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_ALLOW_INSTALL_OBJC_HEADER": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains English and German strings, and that they have variations.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : [ // input
            "en.lproj/Localizable.strings",
            "en.lproj/Localizable.stringsdict",
            "de.lproj/Localizable.strings",
            "de.lproj/Localizable.stringsdict",
                                                                                                                             ]], requiredCommandLine: [
                                                                                                                                "xcstringstool", "compile",
                                                                                                                                "--dry-run",
                                                                                                                                "-l", "de", // installloc builds are language-specific
                                                                                                                                "--output-directory", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build",
                                                                                                                                "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                                                                                                                             ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["INSTALLLOC_LANGUAGE": "de"]), runDestination: .iOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // There should not be any generic CpResource tasks because that would indicate that the xcstrings file is just being copied as is.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // There should be a CompileXCStrings rule.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }


                // Then we need the standard CopyStringsFile tasks to have the compiled .strings/dict as input.
                // Only the German variants should be copied.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/de.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/de.lproj/Localizable.stringsdict"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }

            // And nothing else other than the usuals.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkNoTask()
        }
    }

    // INSTALLLOC_LANGUAGE can be set to multiple languages.
    @Test(.requireSDKs(.iOS))
    func compileMultipleLangsDuringInstallloc() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"), // Note: xcstrings don't belong in lprojs / variant groups.
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT" : "iphoneos",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_ALLOW_INSTALL_OBJC_HEADER": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains English, German, and Japanese strings, and that they have variations.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : [ // input
            "en.lproj/Localizable.strings",
            "en.lproj/Localizable.stringsdict",
            "de.lproj/Localizable.strings",
            "de.lproj/Localizable.stringsdict",
            "ja.lproj/Localizable.strings",
            "ja.lproj/Localizable.stringsdict",
                                                                                                                             ]], requiredCommandLine: [
                                                                                                                                "xcstringstool", "compile",
                                                                                                                                "--dry-run",
                                                                                                                                "-l", "de",
                                                                                                                                "-l", "ja",
                                                                                                                                "--output-directory", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build",
                                                                                                                                "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                                                                                                                             ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["INSTALLLOC_LANGUAGE": "de ja"]), runDestination: .iOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // There should not be any generic CpResource tasks because that would indicate that the xcstrings file is just being copied as is.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // There should be a CompileXCStrings rule.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }


                // Then we need the standard CopyStringsFile tasks to have the compiled .strings/dict as input.
                // English variants should not be copied.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/de.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/de.lproj/Localizable.stringsdict"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/ja.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/ja.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/ja.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/ja.lproj/Localizable.stringsdict"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }

            // And nothing else other than the usuals.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkNoTask()
        }
    }

    // xcstrings files should be skipped entirely during installloc if they're in the Copy Files build phase.
    // We can revisit if we find a legit use case where one would be needed.
    @Test(.requireSDKs(.iOS))
    func installlocCopyFiles() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"), // Note: xcstrings don't belong in lprojs / variant groups.
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT" : "iphoneos",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_ALLOW_INSTALL_OBJC_HEADER": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestCopyFilesBuildPhase([
                            "Localizable.xcstrings"
                        ], destinationSubfolder: .resources, onlyForDeployment: false)
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains English and German strings, and that they have variations.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : [ // input
            "en.lproj/Localizable.strings",
            "en.lproj/Localizable.stringsdict",
            "de.lproj/Localizable.strings",
            "de.lproj/Localizable.stringsdict",
                                                                                                                             ]], requiredCommandLine: [
                                                                                                                                "xcstringstool", "compile",
                                                                                                                                "--dry-run",
                                                                                                                                "-l", "de", // installloc builds are language-specific
                                                                                                                                "--output-directory", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build",
                                                                                                                                "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                                                                                                                             ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["INSTALLLOC_LANGUAGE": "de"]), runDestination: .iOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // Should be skipped.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXCStrings"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }

            // And nothing else other than the usuals.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkNoTask()
        }
    }

    @Test(.requireSDKs(.macOS))
    func forceBuildAllStrings() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "XCSTRINGS_FORCE_BUILD_ALL_STRINGS": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains English and German strings, and that they have variations.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : [ // input
            "en.lproj/Localizable.strings",
            "en.lproj/Localizable.stringsdict",
            "de.lproj/Localizable.strings",
            "de.lproj/Localizable.stringsdict",
                                                                                                                             ]], requiredCommandLine: [
                                                                                                                                "xcstringstool", "compile",
                                                                                                                                "--dry-run",
                                                                                                                                "--force-build-all-strings",
                                                                                                                                "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build",
                                                                                                                                "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                                                                                                                             ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // There should not be any generic CpResource tasks because that would indicate that the xcstrings file is just being copied as is.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // We need a task to compile the XCStrings into .strings and .stringsdict files.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { task in

                    // Input is source xcstrings file.
                    task.checkInputs(contain: [.path("/tmp/Test/Project/Sources/Localizable.xcstrings")])

                    // Outputs are .strings and .stringsdicts in the TempResourcesDir.
                    task.checkOutputs([
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.strings"),
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.stringsdict"),
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.strings"),
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.stringsdict"),
                    ])

                    task.checkCommandLine([
                        "xcstringstool", "compile",
                        "--force-build-all-strings",
                        "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build",
                        "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                    ])
                }


                // Then we need the standard CopyStringsFile tasks to have the compiled .strings/dict as input.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.stringsdict"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.stringsdict"])) { _ in }

                // And these should be the only CopyStringsFile tasks.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func xCStringsInVariantGroup() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestVariantGroup("LegacyView.xib", children: [
                        TestFile("Base.lproj/LegacyView.xib", regionVariantName: "Base"),
                        TestFile("fr.lproj/LegacyView.strings", regionVariantName: "fr"),
                        TestFile("de.lproj/LegacyView.strings", regionVariantName: "de"),
                    ]),
                    TestVariantGroup("View.xib", children: [
                        TestFile("Base.lproj/View.xib", regionVariantName: "Base"),
                        TestFile("mul.lproj/View.xcstrings", regionVariantName: "mul"), // mul is the ISO code for multi-lingual
                    ]),
                    TestVariantGroup("OtherView.nib", children: [
                        TestFile("Base.lproj/OtherView.nib", regionVariantName: "Base"),
                        TestFile("mul.lproj/OtherView.xcstrings", regionVariantName: "mul"),
                    ]),
                    TestVariantGroup("Main.storyboard", children: [
                        TestFile("Base.lproj/Main.storyboard", regionVariantName: "Base"),
                        TestFile("mul.lproj/Main.xcstrings", regionVariantName: "mul"),
                    ])
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "IBC_EXEC": ibtoolPath.str,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "LegacyView.xib",
                            "View.xib",
                            "OtherView.nib",
                            "Main.storyboard",
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains French and German strings.
        // We won't have English because those are in the IB file itself and not typically overridden by xcstrings.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings" : [
                "fr.lproj/View.strings",
                "de.lproj/View.strings",
            ],
            "/tmp/Test/Project/Sources/mul.lproj/OtherView.xcstrings" : [
                "fr.lproj/OtherView.strings",
                "de.lproj/OtherView.strings",
            ],
            "/tmp/Test/Project/Sources/mul.lproj/Main.xcstrings" : [
                "fr.lproj/Main.strings",
                "de.lproj/Main.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // Each xib should get compiled by ibtool.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "/tmp/Test/Project/Sources/Base.lproj/LegacyView.xib"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "/tmp/Test/Project/Sources/Base.lproj/View.xib"])) { _ in }

                // Storyboard has its own compiler and linker.
                results.checkTask(.matchTarget(target), .matchRule(["CompileStoryboard", "/tmp/Test/Project/Sources/Base.lproj/Main.storyboard"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["LinkStoryboards"])) { _ in }

                // Nib should just get copied.
                results.checkTask(.matchTarget(target), .matchRule(["CpResource", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/Base.lproj/OtherView.nib", "/tmp/Test/Project/Sources/Base.lproj/OtherView.nib"])) { _ in }

                // Each xcstrings should get compiled separately by xcstringstool.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/OtherView.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/Main.xcstrings"])) { _ in }

                // Each xcstrings output needs a corresponding CopyStringsFile action.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/fr.lproj/View.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/fr.lproj/View.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/View.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/View.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/fr.lproj/OtherView.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/fr.lproj/OtherView.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/OtherView.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/OtherView.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/fr.lproj/Main.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/fr.lproj/Main.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Main.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Main.strings"])) { _ in }

                // And these should be the only CopyStringsFile tasks.
                // LegacyView should not have one because ibtool is responsible for copying those .strings files.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func xCStringsInVariantGroupDuringInstallloc() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestVariantGroup("LegacyView.xib", children: [
                        TestFile("Base.lproj/LegacyView.xib", regionVariantName: "Base"),
                        TestFile("fr.lproj/LegacyView.strings", regionVariantName: "fr"),
                        TestFile("de.lproj/LegacyView.strings", regionVariantName: "de"),
                    ]),
                    TestVariantGroup("View.xib", children: [
                        TestFile("Base.lproj/View.xib", regionVariantName: "Base"),
                        TestFile("mul.lproj/View.xcstrings", regionVariantName: "mul"), // mul is the ISO code for multi-lingual
                    ]),
                    TestVariantGroup("OtherView.nib", children: [
                        TestFile("Base.lproj/OtherView.nib", regionVariantName: "Base"),
                        TestFile("mul.lproj/OtherView.xcstrings", regionVariantName: "mul"),
                    ]),
                    TestVariantGroup("Main.storyboard", children: [
                        TestFile("Base.lproj/Main.storyboard", regionVariantName: "Base"),
                        TestFile("mul.lproj/Main.xcstrings", regionVariantName: "mul"),
                    ])
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "LegacyView.xib",
                            "View.xib",
                            "OtherView.nib",
                            "Main.storyboard",
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings file contains English and German strings, and that they have variations.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings" : [
                "fr.lproj/View.strings",
                "de.lproj/View.strings",
            ],
            "/tmp/Test/Project/Sources/mul.lproj/OtherView.xcstrings" : [
                "fr.lproj/OtherView.strings",
                "de.lproj/OtherView.strings",
            ],
            "/tmp/Test/Project/Sources/mul.lproj/Main.xcstrings" : [
                "fr.lproj/Main.strings",
                "de.lproj/Main.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["INSTALLLOC_LANGUAGE": "fr"]), runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // xibs won't need compiled because we're only handling fr resources.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXIB"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileStoryboard"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("LinkStoryboards"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // Each xcstrings should get compiled separately by xcstringstool.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings"])) { task in
                    task.checkCommandLineContains(["-l", "fr"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/OtherView.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/Main.xcstrings"])) { _ in }

                // Each fr xcstrings output needs a corresponding CopyStringsFile action.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/View.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/fr.lproj/View.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/OtherView.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/fr.lproj/OtherView.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/Main.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/fr.lproj/Main.strings"])) { _ in }

                // LegacyView should get a direct CopyStringsFile action rather than going through either ibtool or xcstringstool.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/LegacyView.strings", "/tmp/Test/Project/Sources/fr.lproj/LegacyView.strings"])) { _ in }

                // And these should be the only CopyStringsFile tasks.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }

        await tester.checkBuild(BuildParameters(action: .installLoc, configuration: "Release", overrides: ["INSTALLLOC_LANGUAGE": "fr de"]), runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // xibs won't need compiled because we're only handling _Loc_ resources.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXIB"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileStoryboard"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("LinkStoryboards"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // Each xcstrings should get compiled separately by xcstringstool.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings"])) { task in
                    task.checkCommandLineContains(["-l", "fr"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/OtherView.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/Main.xcstrings"])) { _ in }

                // Each fr/de xcstrings output needs a corresponding CopyStringsFile action.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/View.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/fr.lproj/View.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/de.lproj/View.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/de.lproj/View.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/OtherView.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/fr.lproj/OtherView.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/de.lproj/OtherView.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/de.lproj/OtherView.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/Main.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/fr.lproj/Main.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/de.lproj/Main.strings", "/tmp/Test/Project/build/Project.build/Release/MyFramework.build/de.lproj/Main.strings"])) { _ in }

                // LegacyView should get a direct CopyStringsFile action rather than going through either ibtool or xcstringstool.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/fr.lproj/LegacyView.strings", "/tmp/Test/Project/Sources/fr.lproj/LegacyView.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/macosx/MyFramework.framework/Versions/A/Resources/de.lproj/LegacyView.strings", "/tmp/Test/Project/Sources/de.lproj/LegacyView.strings"])) { _ in }

                // And these should be the only CopyStringsFile tasks.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // mul.lproj/View.xcstrings cannot co-exist with <lang>.lproj/View.strings
    @Test(.requireSDKs(.macOS))
    func xCStringsInVariantGroupWithTableOverlap() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestVariantGroup("View.xib", children: [
                        TestFile("Base.lproj/View.xib", regionVariantName: "Base"),
                        TestFile("fr.lproj/View.strings", regionVariantName: "fr"),
                        TestFile("mul.lproj/View.xcstrings", regionVariantName: "mul"),
                    ]),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "IBC_EXEC": ibtoolPath.str,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "View.xib",
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings files contain English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings" : [
                "fr.lproj/View.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            // This is not a supported configuration.
            results.checkError(.and(.contains("View.xcstrings cannot co-exist with other .strings or .stringsdict tables with the same name."), .prefix("/tmp/Test/Project/Sources/mul.lproj/View.xcstrings")))
        }
    }

    // mul.lproj/View.xcstrings cannot co-exist with <lang>.lproj/View.xib override nib
    @Test(.requireSDKs(.macOS))
    func xCStringsInVariantGroupWithOverrideNib() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestVariantGroup("View.xib", children: [
                        TestFile("Base.lproj/View.xib", regionVariantName: "Base"),
                        TestFile("fr.lproj/View.xib", regionVariantName: "fr"),
                        TestFile("mul.lproj/View.xcstrings", regionVariantName: "mul"),
                    ]),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "View.xib",
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Pretend our xcstrings files contain English and German strings, without variation.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings" : [
                "fr.lproj/View.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            // This is not a supported configuration.
            results.checkError(.and(.contains("An IB file cannot provide its localizations via both a String Catalog and other overriding IB files."), .prefix("/tmp/Test/Project/Sources/Base.lproj/View.xib")))
        }
    }

    /// Test an edge case which triggered an obscure bug in `Queue`. We capture here in case that code moves off of that class in the future. c.f. rdar://104582300
    ///
    /// What's happening is that the `Localizable.strings` files are matches with copy rules to produce standalone tasks, but then the rule to process `Localizable.xcstrings` ends up grouping the `.strings` files in its own task in `BuildFilesProcessingContext.mergeGroups()`. This causes `singletonGroups` to be set to an empty list, and the bug was that `Queue.init(:)` would improperly initialize the `array` property. This low-level bug is being tested in `QueueTests.testInitFromEmptySequence()`.
    @Test(.requireSDKs(.macOS))
    func processLocalizableStrings() async throws {

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Localizable.xcstrings"),
                    TestVariantGroup("Localizable.strings", children: [
                        TestFile("en.lproj/Localizable.strings", regionVariantName: "English"),
                        TestFile("de.lproj/Localizable.strings", regionVariantName: "German"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT" : "macosx",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Application", type: .application,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings",
                            "Localizable.strings",
                        ]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            // All we really care about is the error message, and the fact that we didn't crash.
            results.checkError(.contains("Localizable.xcstrings cannot co-exist with other .strings or .stringsdict tables with the same name."))
            results.checkNoDiagnostics()
        }
    }

}
