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

@Suite
fileprivate struct XCStringsSymbolGenTests: CoreBasedTests {

    @Test(.requireSDKs(.macOS))
    func symbolGenerationPlusCompile() async throws {
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES" // This is what we're primarily testing
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

        // Mock xcstringstool since it will be called for --dry-run.
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
        let swiftFeatures = try await self.swiftFeatures

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // There should not be any generic CpResource tasks because that would indicate that the xcstrings file is just being copied as is.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // First there should be symbol gen.
                results.checkTask(.matchTarget(target), .matchRule(["GenerateStringSymbols", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { task in

                    // Input is source xcstrings file.
                    task.checkInputs(contain: [.path("/tmp/Test/Project/Sources/Localizable.xcstrings")])

                    // Output is .swift file.
                    task.checkOutputs([
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift"),
                    ])

                    task.checkCommandLine([
                        "xcstringstool", "generate-symbols",
                        "--language", "swift",
                        "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources",
                        "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                    ])
                }

                // The output of that should be compiled by Swift.
                let targetArchitecture = results.runDestinationTargetArchitecture
                if swiftFeatures.has(.emitLocalizedStrings) {
                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "MyFramework", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [.path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift")])
                    }
                } else {
                    results.checkTask(.matchTarget(target), .matchRule(["CompileSwiftSources", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [.path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift")])
                    }
                }

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

    @Test(.requireSDKs(.macOS))
    func multipleXCStringsSymbolGenerationPlusCompile() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestFile("Localizable.xcstrings"),
                    TestFile("CustomTable.xcstrings"),
                    TestFile("Table with spaces.xcstrings"),
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings",
                            "CustomTable.xcstrings",
                            "Table with spaces.xcstrings",
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
            "/tmp/Test/Project/Sources/Table with spaces.xcstrings" : [
                "en.lproj/Table with spaces.strings",
                "de.lproj/Table with spaces.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let swiftFeatures = try await self.swiftFeatures

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // We should have two separate GenerateStringSymbols tasks.
                results.checkTask(.matchTarget(target), .matchRule(["GenerateStringSymbols", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["GenerateStringSymbols", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_CustomTable.swift", "/tmp/Test/Project/Sources/CustomTable.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["GenerateStringSymbols", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Table with spaces.swift", "/tmp/Test/Project/Sources/Table with spaces.xcstrings"])) { _ in }

                // Both of those output files should be consumed by the Swift Driver.
                let targetArchitecture = results.runDestinationTargetArchitecture
                if swiftFeatures.has(.emitLocalizedStrings) {
                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "MyFramework", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [
                            .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift"),
                            .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_CustomTable.swift"),
                            .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Table with spaces.swift"),
                        ])
                    }
                } else {
                    results.checkTask(.matchTarget(target), .matchRule(["CompileSwiftSources", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [
                            .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift"),
                            .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_CustomTable.swift"),
                            .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Table with spaces.swift"),
                        ])
                    }
                }

                // We should have two separate CompileXCStrings tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/CustomTable.xcstrings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/Table with spaces.xcstrings"])) { _ in }

                // We should then have 4 CopyStringsFile tasks consuming those outputs.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/CustomTable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/CustomTable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/en.lproj/Table with spaces.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/en.lproj/Table with spaces.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/CustomTable.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/CustomTable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/Table with spaces.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/Table with spaces.strings"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // An xcstrings file in Copy Files rather than a Resources build phase should just be copied.
    // (Assuming APPLY_RULES_IN_COPY_FILES has not been set.)
    @Test(.requireSDKs(.macOS))
    func inCopyFilesStillNoSymbolGeneration() async throws {
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
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
                results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateStringSymbols"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXCStrings"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    // Make sure everything still works if a clever developer explicitly puts the xcstrings in Compile Sources for symbol generation.
    @Test(.requireSDKs(.macOS))
    func inSources() async throws {
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES" // This is what we're primarily testing
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift",
                            "Localizable.xcstrings"
                        ]),
                        TestResourcesBuildPhase([

                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Mock xcstringstool since it will be called for --dry-run.
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
        let swiftFeatures = try await self.swiftFeatures

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // There should not be any generic CpResource tasks because that would indicate that the xcstrings file is just being copied as is.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpResource"))

                // First there should be symbol gen.
                results.checkTask(.matchTarget(target), .matchRule(["GenerateStringSymbols", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { task in

                    // Input is source xcstrings file.
                    task.checkInputs(contain: [.path("/tmp/Test/Project/Sources/Localizable.xcstrings")])

                    // Output is .swift file.
                    task.checkOutputs([
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift"),
                    ])

                    task.checkCommandLine([
                        "xcstringstool", "generate-symbols",
                        "--language", "swift",
                        "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources",
                        "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                    ])
                }

                // The output of that should be compiled by Swift.
                let targetArchitecture = results.runDestinationTargetArchitecture
                if swiftFeatures.has(.emitLocalizedStrings) {
                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "MyFramework", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [.path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift")])
                    }
                } else {
                    results.checkTask(.matchTarget(target), .matchRule(["CompileSwiftSources", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [.path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift")])
                    }
                }

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

    // Test both .xcstrings and .strings tables when symbol generation is enabled.
    @Test(.requireSDKs(.macOS))
    func mixedProjectWithSymbolGeneration() async throws {
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
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
                // GenerateStringSymbols
                results.checkTask(.matchTarget(target), .matchRule(["GenerateStringSymbols", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }

                // CompileXCStrings
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

    // Don't generate symbols if the project doesn't have Swift files.
    @Test(.requireSDKs(.macOS))
    func testNoSwiftSourcesNoSymbolGen() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.h"),
                    TestFile("MyFramework.m"),
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            "MyFramework.h"
                        ]),
                        TestSourcesBuildPhase([
                            "MyFramework.m"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )
            ],
            developmentRegion: "en"
        )

        // Mock xcstringstool since it will be called for --dry-run.
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

                // No symbol gen
                results.checkNoTask(.matchRuleType("GenerateStringSymbols"))

                // We need a task to compile the XCStrings into .strings and .stringsdict files.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }


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
    func symbolGenPlusTableOverlap() async throws {
        let catalog1 = TestFile("Dupe.xcstrings", guid: UUID().uuidString)
        let catalog2 = TestFile("Dupe.xcstrings", guid: UUID().uuidString)

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
                    catalog1,
                    TestGroup("Subdir", path: "Subdir", children: [
                        catalog2
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyFramework.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings",
                            "Localizable.strings",
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
            "/tmp/Test/Project/Sources/Dupe.xcstrings" : [
                "en.lproj/Dupe.strings",
                "de.lproj/Dupe.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            // This is not a supported configuration.

            results.checkError(.and(.contains("Localizable.xcstrings cannot co-exist with other .strings or .stringsdict tables with the same name."), .prefix("/tmp/Test/Project/Sources/Localizable.xcstrings")))

            results.checkError(.contains("Cannot have multiple Dupe.xcstrings files in same target."))
        }
    }

    @Test(.requireSDKs(.iOS))
    func installlocNoSymbolGeneration() async throws {
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
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
                // No symbol gen in installloc.
                results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateStringSymbols"))

                // We need a task to compile the XCStrings into .strings and .stringsdict files.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { _ in }


                // Then we need the standard CopyStringsFile tasks to have the compiled .strings/dict as input.
                // Only the German variants should be copied.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/de.lproj/Localizable.strings", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/de.lproj/Localizable.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/UninstalledProducts/iphoneos/MyFramework.framework/de.lproj/Localizable.stringsdict", "/tmp/Test/Project/build/Project.build/Release-iphoneos/MyFramework.build/de.lproj/Localizable.stringsdict"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))

                // And nothing else other than the usuals.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkNoTask()
            }
        }
    }

    // xcstrings files should be skipped entirely during installloc if they're in the Copy Files build phase.
    // We can revisit if we find a legit use case where one would be needed.
    @Test(.requireSDKs(.iOS))
    func installlocCopyFileNoSymbolGeneration() async throws {
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
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
                results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateStringSymbols"))
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
    func xcstringsInVariantGroupNoSymbolGeneration() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "ProjectSources",
                path: "Sources",
                children: [
                    TestFile("MyFramework.swift"),
                    TestVariantGroup("View.xib", children: [
                        TestFile("Base.lproj/View.xib", regionVariantName: "Base"),
                        TestFile("mul.lproj/View.xcstrings", regionVariantName: "mul"), // mul is the ISO code for multi-lingual
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
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

        // Pretend our xcstrings file contains French and German strings.
        // We won't have English because those are in the IB file itself and not typically overridden by xcstrings.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [
            "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings" : [
                "fr.lproj/View.strings",
                "de.lproj/View.strings",
            ],
        ], requiredCommandLine: nil)

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // xib should get compiled by ibtool.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXIB", "/tmp/Test/Project/Sources/Base.lproj/View.xib"])) { _ in }

                // No symbol generation for xcstrings in variant groups because those are only used by IB.
                results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateStringSymbols"))

                // xcstrings should get compiled separately by xcstringstool.
                results.checkTask(.matchTarget(target), .matchRule(["CompileXCStrings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/", "/tmp/Test/Project/Sources/mul.lproj/View.xcstrings"])) { _ in }

                // Each xcstrings output needs a corresponding CopyStringsFile action.
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/fr.lproj/View.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/fr.lproj/View.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/Project/build/Debug/MyFramework.framework/Versions/A/Resources/de.lproj/View.strings", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/de.lproj/View.strings"])) { _ in }

                // And these should be the only CopyStringsFile tasks.
                // LegacyView should not have one because ibtool is responsible for copying those .strings files.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func exportLocSymbolGeneration() async throws {
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
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES"
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

        // xcstringstool should not be called during planning since exportloc should not compile xcstrings.
        let xcstringsTool = MockXCStringsTool(relativeOutputFilePaths: [ "/tmp/Test/Project/Sources/Localizable.xcstrings" : [ // input
            "en.lproj/Localizable.strings",
            "en.lproj/Localizable.stringsdict",
            "de.lproj/Localizable.strings",
            "de.lproj/Localizable.stringsdict",
        ]], requiredCommandLine: [
            "don't call me"
        ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let swiftFeatures = try await self.swiftFeatures

        await tester.checkBuild(BuildParameters(action: .exportLoc, configuration: "Debug"), runDestination: .macOS, clientDelegate: xcstringsTool) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MyFramework") { target in
                // We DO expect symbol generation.
                results.checkTask(.matchTarget(target), .matchRule(["GenerateStringSymbols", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift", "/tmp/Test/Project/Sources/Localizable.xcstrings"])) { task in

                    // Input is source xcstrings file.
                    task.checkInputs(contain: [.path("/tmp/Test/Project/Sources/Localizable.xcstrings")])

                    // Output is .swift file.
                    task.checkOutputs([
                        .path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift"),
                    ])

                    task.checkCommandLine([
                        "xcstringstool", "generate-symbols",
                        "--language", "swift",
                        "--output-directory", "/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources",
                        "/tmp/Test/Project/Sources/Localizable.xcstrings" // input file
                    ])
                }

                // The output of that should be compiled by Swift.
                let targetArchitecture = results.runDestinationTargetArchitecture
                if swiftFeatures.has(.emitLocalizedStrings) {
                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "MyFramework", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [.path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift")])
                    }
                } else {
                    results.checkTask(.matchTarget(target), .matchRule(["CompileSwiftSources", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkInputs(contain: [.path("/tmp/Test/Project/build/Project.build/Debug/MyFramework.build/DerivedSources/GeneratedStringSymbols_Localizable.swift")])
                    }
                }

                // No actual catalog compilation.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileXCStrings"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CopyStringsFile"))
            }
        }
    }

}
