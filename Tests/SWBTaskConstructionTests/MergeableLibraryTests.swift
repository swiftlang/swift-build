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

import SWBUtil
import enum SWBProtocol.BuildAction
import struct SWBProtocol.RunDestinationInfo
@_spi(Testing) import SWBCore
import SWBTestSupport

@Suite
fileprivate struct MergeableLibraryTests: CoreBasedTests {
    /// Test automatically creating a merged framework via `MERGED_BINARY_TYPE = automatic` causing its immediate dependencies to be mergeable libraries.
    ///
    /// - remark: This is the main test to exercise a broad spectrum of automatic merged framework behavior, since it was originally written for iOS.  `testAutomaticMergedFrameworkCreation_macOS()` tests some differences specific to macOS.
    @Test(.requireSDKs(.iOS))
    func automaticMergedFrameworkCreation_iOS() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("Application.swift"),

                    // Mergeable framework and library sources
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                    TestFile("ClassThree.swift"),

                    // Other files
                    TestFile("External.framework"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                // App target
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Application.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "MergedFwkTarget.framework",
                        ]),
                        // Embed
                        TestCopyFilesBuildPhase([
                            TestBuildFile("MergedFwkTarget.framework", codeSignOnCopy: true),
                            TestBuildFile("FwkTarget1.framework", codeSignOnCopy: true),
                            TestBuildFile("FwkTarget2.framework", codeSignOnCopy: true),
                            TestBuildFile("libDylibTarget1.dylib", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                    ],
                    dependencies: ["MergedFwkTarget"]
                ),
                // Merged framework target
                TestStandardTarget(
                    "MergedFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGED_BINARY_TYPE": "automatic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            // There are intentionally no sources for this target, since a common mode is to have a merged framework which does nothing but merge several other frameworks together.
                        ]),
                        TestFrameworksBuildPhase([
                            "FwkTarget1.framework",
                            "FwkTarget2.framework",
                            "libDylibTarget1.dylib",
                            // We also want to test that we can link a framework without merging it.
                            "External.framework",
                        ]),
                    ],
                    // We want to test both explicit and implicit dependencies so not all targets are listed here.
                    dependencies: ["FwkTarget1"]
                ),
                // Mergeable framework and library targets
                TestStandardTarget(
                    "FwkTarget1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "FwkTarget2",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "DylibTarget1",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassThree.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let runDestination = RunDestinationInfo.iOS
        let CONFIGURATION = "Config"
        let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
        let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
        let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""

        // Test a debug build.  This will just build the merged framework to reexport the frameworks it links against.
        do {
            let buildType = "Debug"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                "GCC_OPTIMIZATION_LEVEL": "0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ])
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the mergeable targets were *not* build to be mergeable.
                for targetName in ["FwkTarget1", "FwkTarget2"] {
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    results.checkTarget(targetName) { target in
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-make_mergeable")      // Not passed in debug builds
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                        results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                    }
                }
                results.checkTarget("DylibTarget1") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).dylib"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-make_mergeable")      // Not passed in debug builds
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check that the merged framework was built with -no_merge_framework.
                results.checkTarget("MergedFwkTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-rpath", "-Xlinker", "@loader_path/\(reexportedBinariesDirectoryName)"],
                            ["-Xlinker", "-no_merge_framework", "-Xlinker", "FwkTarget1",
                             "-Xlinker", "-no_merge_framework", "-Xlinker", "FwkTarget2",
                             "-Xlinker", "-no_merge-lDylibTarget1",
                             "-framework", "External",
                            ],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-merge_framework")
                        task.checkCommandLineDoesNotContain("-merge-lDylibTarget1")
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget1"), .matchRuleType("Ld")])
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget2"), .matchRuleType("Ld")])
                    }

                    // Check that we're copy-and-resigning the binaries we're reexporting.
                    for fwkTargetName in ["FwkTarget1", "FwkTarget2"] {
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkRuleInfo(["Copy", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(FWK_FULL_PRODUCT_NAME)", "\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)"])
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkTargetName)",
                                 "-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)_CodeSignature",
                                 "-include_only_subpath", "Info.plist",
                                ],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)"],
                            ].reduce([], +))
                            let numberOfIncludeOnlySubpath = task.commandLineAsStrings.filter({ $0 == "-include_only_subpath" } ).count
                            #expect(numberOfIncludeOnlySubpath == 3, "Expected 3 -include_only_subpath, found \(numberOfIncludeOnlySubpath): \(Array(task.commandLineAsStrings))")
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            task.checkRuleInfo(["CodeSign", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(signedDir)"])
                            task.checkCommandLineContains(["/usr/bin/codesign", "--preserve-metadata=identifier,entitlements,flags", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(signedDir)"])
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }
                    do {
                        let dylibTargetName = "DylibTarget1"
                        let DYLIB_FULL_PRODUCT_NAME = "lib\(dylibTargetName).dylib"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(DYLIB_FULL_PRODUCT_NAME)) { task in
                            task.checkRuleInfo(["Copy", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(DYLIB_FULL_PRODUCT_NAME)", "\(BUILT_PRODUCTS_DIR)/\(DYLIB_FULL_PRODUCT_NAME)"])
                            task.checkCommandLineDoesNotContain("-include_only_subpath")
                            results.checkTaskFollows(task, [.matchTargetName(dylibTargetName), .matchRuleType("CodeSign")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(DYLIB_FULL_PRODUCT_NAME)) { task in
                            task.checkRuleInfo(["CodeSign", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(DYLIB_FULL_PRODUCT_NAME)"])
                            task.checkCommandLineContains(["/usr/bin/codesign", "--preserve-metadata=identifier,entitlements,flags", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(DYLIB_FULL_PRODUCT_NAME)"])
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(DYLIB_FULL_PRODUCT_NAME)])
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "MergedFwkTarget"],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that the frameworks are being embedded, the mergeable frameworks without their binary. The dylib should not be embedded.
                    for fwkTargetName in ["FwkTarget1", "FwkTarget2"] {
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkTargetName)"],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("DylibTarget1.dylib"))
                    do {
                        let mergedTargetName = "MergedFwkTarget"
                        let FWK_FULL_PRODUCT_NAME = "\(mergedTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                            results.checkTaskFollows(task, [.matchTargetName(mergedTargetName), .matchRuleType("Touch"), .matchRuleItemBasename("MergedFwkTarget.framework")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test a release build.  This will build the dependencies to be mergeable, and merge them into the top-level framework.
        do {
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the mergeable targets were built to be mergeable.
                for targetName in ["FwkTarget1", "FwkTarget2"] {
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    let INSTALL_PATH = "/Library/Frameworks"
                    results.checkTarget(targetName) { target in
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-Xlinker", "-make_mergeable"],
                                ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                            ].reduce([], +))
                        }
                        // Don't generate an intermediate .tbd file for eager linking when we're making the binary mergeable.
                        results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                        // Mergeable products should not be stripped.
                        results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                        results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                    }
                }
                results.checkTarget("DylibTarget1") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).dylib"
                    let INSTALL_PATH = "/usr/local/lib"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-make_mergeable"],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain(reexportedBinariesDirectoryName)
                    }
                    // Mergeable products should not be stripped.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check that the merged framework was built with -merge_framework.
                results.checkTarget("MergedFwkTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    let INSTALL_PATH = "/Library/Frameworks"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-merge_framework", "-Xlinker", "FwkTarget1",
                             "-Xlinker", "-merge_framework", "-Xlinker", "FwkTarget2",
                             "-Xlinker", "-merge-lDylibTarget1",
                             "-framework", "External",
                            ],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-no_merge_framework")
                        task.checkCommandLineDoesNotContain("-no_merge-lDylibTarget1")
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget1"), .matchRuleType("Ld")])
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget2"), .matchRuleType("Ld")])
                        results.checkTaskFollows(task, [.matchTargetName("DylibTarget1"), .matchRuleType("Ld")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    // Check that we're not embedding the binaries into this target, because this is not the debug/reexport workflow.
                    for mergeableTargetProductName in ["FwkTarget1.framework", "FwkTarget2.framework", "libDylibTarget1.dylib"] {
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename(mergeableTargetProductName))
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    let INSTALL_PATH = "/Applications"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "MergedFwkTarget"],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that we are removing the binary from the mergeable frameworks (because they got merged into the merged framework), that we're not copying the dylib at all (because it got merged into the merged framework), and we're not doing anything special to the merged framework.
                    for fwkTargetName in ["FwkTarget1", "FwkTarget2"] {
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkTargetName)"],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("DylibTarget1.dylib"))
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("DylibTarget1.dylib"))
                    do {
                        let fwkTargetName = "MergedFwkTarget"
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func automaticMergedFrameworkCreation_macOS() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("Application.swift"),

                    // Mergeable framework and library sources
                    TestFile("ClassOne.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "macosx",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                // App target
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Application.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "MergedFwkTarget.framework",
                        ]),
                        // Embed
                        TestCopyFilesBuildPhase([
                            TestBuildFile("MergedFwkTarget.framework", codeSignOnCopy: true),
                            TestBuildFile("FwkTarget1.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                    ],
                    dependencies: ["MergedFwkTarget"]
                ),
                // Merged framework target
                TestStandardTarget(
                    "MergedFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGED_BINARY_TYPE": "automatic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            // There are intentionally no sources for this target, since a common mode is to have a merged framework which does nothing but merge several other frameworks together.
                        ]),
                        TestFrameworksBuildPhase([
                            "FwkTarget1.framework",
                        ]),
                    ],
                    // We want to test both explicit and implicit dependencies so not all targets are listed here.
                    dependencies: ["FwkTarget1"]
                ),
                // Mergeable framework and library targets
                TestStandardTarget(
                    "FwkTarget1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let runDestination = RunDestinationInfo.macOS
        let CONFIGURATION = "Config"
        let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
        let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
        let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""

        // Test a debug build.  This will just build the merged framework to reexport the frameworks it links against.
        do {
            let buildType = "Debug"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                "GCC_OPTIMIZATION_LEVEL": "0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ])
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the mergeable target was *not* build to be mergeable.
                do {
                    let targetName = "FwkTarget1"
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    results.checkTarget(targetName) { target in
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-make_mergeable")      // Not passed in debug builds
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                        results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                    }
                }

                // Check that the merged framework was built with -no_merge_framework.
                results.checkTarget("MergedFwkTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-rpath", "-Xlinker", "@loader_path/\(reexportedBinariesDirectoryName)"],
                            ["-Xlinker", "-no_merge_framework", "-Xlinker", "FwkTarget1"],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-merge_framework")
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget1"), .matchRuleType("Ld")])
                    }

                    // Check that we're copy-and-resigning the binaries we're reexporting.
                    do {
                        let fwkTargetName = "FwkTarget1"
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkRuleInfo(["Copy", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(FWK_FULL_PRODUCT_NAME)", "\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)"])
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkTargetName)",
                                 "-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)_CodeSignature",
                                 "-include_only_subpath", "Versions/A/Resources/Info.plist",
                                 "-include_only_subpath", fwkTargetName,
                                 "-include_only_subpath", "Versions/Current",
                                ],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)"],
                            ].reduce([], +))
                            let numberOfIncludeOnlySubpath = task.commandLineAsStrings.filter({ $0 == "-include_only_subpath" } ).count
                            #expect(numberOfIncludeOnlySubpath == 5, "Expected 5 -include_only_subpath, found \(numberOfIncludeOnlySubpath): \(Array(task.commandLineAsStrings))")
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            task.checkRuleInfo(["CodeSign", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(signedDir)"])
                            task.checkCommandLineContains(["/usr/bin/codesign", "--preserve-metadata=identifier,entitlements,flags", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(reexportedBinariesDirectoryName)/\(signedDir)"])
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "MergedFwkTarget"],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that the frameworks are being embedded, the mergeable frameworks without their binary. The dylib should not be embedded.
                    do {
                        let fwkTargetName = "FwkTarget1"
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkTargetName)"],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }
                    do {
                        let mergedTargetName = "MergedFwkTarget"
                        let FWK_FULL_PRODUCT_NAME = "\(mergedTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                            results.checkTaskFollows(task, [.matchTargetName(mergedTargetName), .matchRuleType("Touch"), .matchRuleItemBasename("MergedFwkTarget.framework")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test a release build.  This will build the dependencies to be mergeable, and merge them into the top-level framework.
        do {
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the mergeable targets were *not* built to be mergeable.
                do {
                    let targetName = "FwkTarget1"
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    let INSTALL_PATH = "/Library/Frameworks"
                    results.checkTarget(targetName) { target in
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-Xlinker", "-make_mergeable"],
                                ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                            ].reduce([], +))
                        }
                        // Don't generate an intermediate .tbd file for eager linking when we're making the binary mergeable.
                        results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                        // Mergeable products should not be stripped.
                        results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                        results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                    }
                }

                // Check that the merged framework was built with -merge_framework.
                results.checkTarget("MergedFwkTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    let INSTALL_PATH = "/Library/Frameworks"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-merge_framework", "-Xlinker", "FwkTarget1"],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-no_merge_framework")
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget1"), .matchRuleType("Ld")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    // Check that we're not embedding the binaries into this target, because this is not the debug/reexport workflow.
                    for mergeableTargetProductName in ["FwkTarget1.framework"] {
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename(mergeableTargetProductName))
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    let INSTALL_PATH = "/Applications"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "MergedFwkTarget"],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that we are removing the binary from the mergeable frameworks (because they got merged into the merged framework), that we're not copying the dylib at all (because it got merged into the merged framework), and we're not doing anything special to the merged framework.
                    do {
                        let fwkTargetName = "FwkTarget1"
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkTargetName)"],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }
                    do {
                        let fwkTargetName = "MergedFwkTarget"
                        let FWK_FULL_PRODUCT_NAME = "\(fwkTargetName).framework"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["\(BUILT_PRODUCTS_DIR)/\(FWK_FULL_PRODUCT_NAME)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        let signedDir = String("\(FWK_FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)".dropLast())       // Chop off the trailing '/'
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(FWK_FULL_PRODUCT_NAME)])
                        }
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test automatically creating a merged framework via `MERGED_BINARY_TYPE = automatic` where the mergeable framework is in a different project from the merged framework.
    @Test(.requireSDKs(.iOS))
    func multiProjectAutomaticMergedFrameworkCreation() async throws {

        let testWorkspace = try await TestWorkspace(
            "aWorkspace",
            projects: [
                TestProject(
                    "AppProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            // App sources
                            TestFile("Application.swift"),

                            // Merged framework sources
                            TestFile("FwkTarget.framework", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR")),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Config",
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "CODE_SIGN_IDENTITY": "-",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "SKIP_INSTALL": "YES",
                                "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                                "TAPI_EXEC": tapiToolPath.str,
                            ]),
                    ],
                    targets: [
                        // App target
                        TestStandardTarget(
                            "AppTarget",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Config",
                                                       buildSettings: [
                                                        "SKIP_INSTALL": "NO",
                                                       ]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    "Application.swift",
                                ]),
                                TestFrameworksBuildPhase([
                                    "MergedFwkTarget.framework",
                                ]),
                                // Embed
                                TestCopyFilesBuildPhase([
                                    TestBuildFile("MergedFwkTarget.framework", codeSignOnCopy: true),
                                    TestBuildFile(.file("FwkTarget.framework"), codeSignOnCopy: true),
                                ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                            ],
                            dependencies: ["MergedFwkTarget"]
                        ),
                        // Merged framework target
                        TestStandardTarget(
                            "MergedFwkTarget",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Config",
                                                       buildSettings: [
                                                        "MERGED_BINARY_TYPE": "automatic",
                                                       ]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    // There are intentionally no sources for this target, since a common mode is to have a merged framework which does nothing but merge several other frameworks together.
                                ]),
                                TestFrameworksBuildPhase([
                                    TestBuildFile(.file("FwkTarget.framework")),
                                ]),
                            ]
                        ),
                    ]),
                TestProject(
                    "FwkProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            // Mergeable framework sources
                            TestFile("ClassOne.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Config",
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "CODE_SIGN_IDENTITY": "-",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "SKIP_INSTALL": "YES",
                                "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                                "TAPI_EXEC": tapiToolPath.str,
                            ]),
                    ],
                    targets: [
                        // Mergeable framework and library targets
                        TestStandardTarget(
                            "FwkTarget",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Config"),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    "ClassOne.swift",
                                ]),
                                TestFrameworksBuildPhase([
                                ]),
                            ]
                        ),
                    ]),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testWorkspace)

        // Test a debug build.  This will build the merged framework to reexport the frameworks it links against.
        do {
            let buildType = "Debug"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: "Config", overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                "GCC_OPTIMIZATION_LEVEL": "0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ])
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: .iOS, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the mergeable target was *not* built to be mergeable.
                results.checkTarget("FwkTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-o", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-make_mergeable")      // Not passed in debug builds
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check that the merged framework was built with -no_merge_framework.
                results.checkTarget("MergedFwkTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-rpath", "-Xlinker", "@loader_path/\(reexportedBinariesDirectoryName)"],
                            ["-Xlinker", "-no_merge_framework", "-Xlinker", "FwkTarget"],
                            ["-o", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-merge_framework")
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that we're copy-and-resigning the mergeable framework.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                        task.checkRuleInfo(["Copy", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(reexportedBinariesDirectoryName)/FwkTarget.framework", "\(SYMROOT)/Config-iphoneos/FwkTarget.framework"])
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-include_only_subpath", "FwkTarget",
                             "-include_only_subpath", "_CodeSignature",
                            ],
                            ["\(SYMROOT)/Config-iphoneos/FwkTarget.framework", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(reexportedBinariesDirectoryName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget"), .matchRuleType("Touch")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                        task.checkRuleInfo(["CodeSign", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(reexportedBinariesDirectoryName)/FwkTarget.framework"])
                        task.checkCommandLineContains(["/usr/bin/codesign", "--preserve-metadata=identifier,entitlements,flags", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(reexportedBinariesDirectoryName)/FwkTarget.framework"])
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")])
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "MergedFwkTarget"],
                            ["-o", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(targetName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that we are removing the binary from the mergeable framework (because it got merged into the merged framework), and that we're not doing anything special to the merged framework.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-exclude_subpath", "FwkTarget"],
                            ["\(SYMROOT)/Config-iphoneos/FwkTarget.framework", "\(SYMROOT)/Config-iphoneos/\(targetName).app/Frameworks"]
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget"), .matchRuleType("Touch")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                        // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("MergedFwkTarget.framework")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["\(SYMROOT)/Config-iphoneos/MergedFwkTarget.framework", "\(SYMROOT)/Config-iphoneos/\(targetName).app/Frameworks"]
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-exclude_subpath")
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Touch")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("MergedFwkTarget.framework")) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("MergedFwkTarget.framework")])
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test a release build.  This will build the mergeable targets to be mergeable, and build the merged framework to merge them.
        do {
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: "Config", overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: .iOS, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the mergeable target was *not* built to be mergeable.
                results.checkTarget("FwkTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-make_mergeable"],
                            ["-o", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)"],
                        ].reduce([], +))
                    }
                    // Don't generate an intermediate .tbd file for eager linking when we're making the binary mergeable.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                    // Mergeable products should not be stripped.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check that the merged framework was built with -merge_framework.
                results.checkTarget("MergedFwkTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-merge_framework", "-Xlinker", "FwkTarget"],
                            ["-o", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-no_merge_framework")
                        task.checkCommandLineDoesNotContain(reexportedBinariesDirectoryName)
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that we're not embedding the mergeable framework's binary into this target, because this is not the debug/reexport workflow.
                    results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework"))

                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(DSTROOT)/Applications/\(targetName).app/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "MergedFwkTarget"],
                            ["-o", "\(DSTROOT)/Applications/\(targetName).app/\(targetName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that we are removing the binary from the mergeable framework (because it got merged into the merged framework), and that we're not doing anything special to the merged framework.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-exclude_subpath", "FwkTarget"],
                            ["\(SYMROOT)/Config-iphoneos/FwkTarget.framework", "\(DSTROOT)/Applications/\(targetName).app/Frameworks"]
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("FwkTarget"), .matchRuleType("Touch")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                        // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("MergedFwkTarget.framework")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["\(SYMROOT)/Config-iphoneos/MergedFwkTarget.framework", "\(DSTROOT)/Applications/\(targetName).app/Frameworks"]
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-exclude_subpath")
                        results.checkTaskFollows(task, [.matchTargetName("MergedFwkTarget"), .matchRuleType("Touch")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("MergedFwkTarget.framework")) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("MergedFwkTarget.framework")])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test using XCFrameworks with a mergeable framework and library for the device, but a standard dylib for the simulator.
    @Test(.requireSDKs(.iOS))
    func xCFrameworkWithMergeableLibrary_iOS() async throws {

        let CONFIGURATION = "Config"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Framework.xcframework"),
                    TestFile("Dylib.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration(CONFIGURATION, buildSettings: [
                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                    "COPY_PHASE_STRIP": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "MERGE_LINKED_LIBRARIES": "$(APP_MERGE_LINKED_LIBRARIES)",      // Builds below can override APP_MERGE_LINKED_LIBRARIES to NO to disable merging.
                    "APP_MERGE_LINKED_LIBRARIES": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "auto",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(CONFIGURATION),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase([
                            "Framework.xcframework",
                            "Dylib.xcframework",
                        ]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("Framework.xcframework", codeSignOnCopy: true),
                            TestBuildFile("Dylib.xcframework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                    ],
                    dependencies: []
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let infoLookup = try await getCore()

        let iosLibraryIdentifier = "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)"
        let iossimLibraryIdentifier = "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)-simulator"

        let fwkBaseName = "Framework"
        let fwkFullProductName = "\(fwkBaseName).framework"
        let fwkXCFramework = try XCFramework(version: XCFramework.mergeableMetadataVersion, libraries: [
            XCFramework.Library(libraryIdentifier: iosLibraryIdentifier, supportedPlatform: "ios", supportedArchitectures: ["arm64"], platformVariant: nil, libraryPath: Path(fwkFullProductName), binaryPath: Path("\(fwkFullProductName)/\(fwkBaseName)"), headersPath: nil, mergeableMetadata: true),
            XCFramework.Library(libraryIdentifier: iossimLibraryIdentifier, supportedPlatform: "ios", supportedArchitectures: ["arm64"], platformVariant: "simulator", libraryPath: Path(fwkFullProductName), binaryPath: Path("\(fwkFullProductName)/\(fwkBaseName)"), headersPath: nil),
        ])
        let fwkXCFrameworkPath = Path(SRCROOT).join("\(fwkBaseName).xcframework")
        try fs.createDirectory(fwkXCFrameworkPath, recursive: true)
        try await XCFrameworkTestSupport.writeXCFramework(fwkXCFramework, fs: fs, path: fwkXCFrameworkPath, infoLookup: infoLookup)

        let libBaseName = "Dylib"
        let libFullProductName = "lib\(libBaseName).dylib"
        let libXCFramework = try XCFramework(version: XCFramework.mergeableMetadataVersion, libraries: [
            XCFramework.Library(libraryIdentifier: iosLibraryIdentifier, supportedPlatform: "ios", supportedArchitectures: ["arm64"], platformVariant: nil, libraryPath: Path(libFullProductName), binaryPath: Path("\(libFullProductName)"), headersPath: nil, mergeableMetadata: true),
            XCFramework.Library(libraryIdentifier: iossimLibraryIdentifier, supportedPlatform: "ios", supportedArchitectures: ["arm64"], platformVariant: "simulator", libraryPath: Path(libFullProductName), binaryPath: Path("\(libFullProductName)"), headersPath: nil),
        ])
        let libXCFrameworkPath = Path(SRCROOT).join("\(libBaseName).xcframework")
        try fs.createDirectory(libXCFrameworkPath, recursive: true)
        try await XCFrameworkTestSupport.writeXCFramework(libXCFramework, fs: fs, path: libXCFrameworkPath, infoLookup: infoLookup)

        // Check a debug build for iOS device, where we reexport the XCFrameworks.
        do {
            let runDestination = RunDestinationInfo.iOS
            let buildType = "Debug"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "ARCHS": "arm64",
                "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                "GCC_OPTIMIZATION_LEVEL": "0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ])
            let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
            let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
            let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(fwkBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }
                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(libBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }

                results.checkTarget("App") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    // Check that we're merging the XCFramework during linking.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-no_merge_framework", "-Xlinker", "\(fwkBaseName)"],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                    }

                    // Check that we're copying the framework twice, once with its binary and once without.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks/\(fwkFullProductName)")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)"],
                            ["\(fwkXCFrameworkPath.str)/\(iosLibraryIdentifier)/\(fwkFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks/\(fwkFullProductName)")) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks/\(fwkFullProductName)")])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries/\(fwkFullProductName)")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)",
                             "-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)_CodeSignature",
                             "-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)Info.plist",
                            ],
                            ["-strip_subpath", "\(fwkFullProductName)/\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)"],
                            ["\(BUILT_PRODUCTS_DIR)/\(fwkFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries"]
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries/\(fwkFullProductName)")) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries/\(fwkFullProductName)")])
                    }

                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName))
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(fwkFullProductName))

                    // Check that we're copying the library only once.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-strip_subpath", "\(libFullProductName)"],
                            ["\(BUILT_PRODUCTS_DIR)/\(libFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries"]
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-exclude_subpath")
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(libFullProductName))) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)])
                    }

                    results.checkNoDiagnostics()
                }
            }
        }

        // Check a debug build for iOS simulator, where we don't reexport the binaries, because the XCFrameworks aren't built for mergeability in this case.
        do {
            let runDestination = RunDestinationInfo.iOSSimulator
            let buildType = "Debug"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "ARCHS": "arm64",
                "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                "GCC_OPTIMIZATION_LEVEL": "0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ])
            //let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
            let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
            let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(fwkBaseName).xcframework", "--platform", "ios", "--environment", "simulator", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }
                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(libBaseName).xcframework", "--platform", "ios", "--environment", "simulator", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }

                results.checkTarget("App") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    // Check that we're merging the XCFramework during linking.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-no_merge_framework")
                    }

                    // Check that we're copying the framework and library once each.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["\(fwkXCFrameworkPath.str)/\(iossimLibraryIdentifier)/\(fwkFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-exclude_subpath")
                        task.checkCommandLineDoesNotContain("-include_only_subpath")
                        task.checkCommandLineDoesNotContain("-strip_subpath")
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(fwkFullProductName)) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["\(libXCFrameworkPath.str)/\(iossimLibraryIdentifier)/\(libFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-exclude_subpath")
                        task.checkCommandLineDoesNotContain("-include_only_subpath")
                        task.checkCommandLineDoesNotContain("-strip_subpath")
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(libFullProductName))) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)])
                    }

                    results.checkNoDiagnostics()
                }
            }
        }

        // Check a release build for iOS device, where we merge the XCFrameworks.
        do {
            let runDestination = RunDestinationInfo.iOS
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "ARCHS": "arm64",
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
            let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
            let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(fwkBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }
                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(libBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }

                results.checkTarget("App") { target in
                    // Check that we're merging the XCFramework during linking.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        let targetName = target.target.name
                        let FULL_PRODUCT_NAME = "\(targetName).app"
                        let INSTALL_PATH = "/Applications"
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-merge_framework", "-Xlinker", "\(fwkBaseName)"],
                            ["-Xlinker", "-merge-l\(libBaseName)"],
                            ["-o", "\(DSTROOT)/Applications/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))

                        // Check that we're copying the framework appropriately.
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)"],
                                ["\(fwkXCFrameworkPath.str)/\(iosLibraryIdentifier)/\(fwkFullProductName)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-strip_subpath")
                            results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        }
                        let signedDir = fwkFullProductName
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)])
                        }

                        // Check that we're not copying the dylib at all.
                        results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName))
                    }

                    results.checkNoDiagnostics()
                }
            }
        }

        // Check a release build for iOS device, but *don't* merge the XCFrameworks.  This validates that we link and embed them as normal libraries, and strip the mergeable metadata.
        do {
            let runDestination = RunDestinationInfo.iOS
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "ARCHS": "arm64",
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
                "APP_MERGE_LINKED_LIBRARIES": "NO",
            ])
            let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
            let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
            let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(fwkBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }
                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(libBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }

                results.checkTarget("App") { target in
                    // Check that we're merging the XCFramework during linking.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        let targetName = target.target.name
                        let FULL_PRODUCT_NAME = "\(targetName).app"
                        let INSTALL_PATH = "/Applications"
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "\(fwkBaseName)"],
                            ["-l\(libBaseName)"],
                            ["-o", "\(DSTROOT)/Applications/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))

                        // Check that we're copying both the framework and the library appropriately.
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-strip_subpath", "\(fwkFullProductName)/\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)"],
                                ["\(fwkXCFrameworkPath.str)/\(iosLibraryIdentifier)/\(fwkFullProductName)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                            results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(fwkFullProductName))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)])
                        }

                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-strip_subpath", "\(libFullProductName)"],
                                ["\(libXCFrameworkPath.str)/\(iosLibraryIdentifier)/\(libFullProductName)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(libFullProductName))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)])
                        }
                    }

                    results.checkNoDiagnostics()
                }
            }
        }

        // Check a release build for iOS simulator, where merging does not occur even though we are merging linked libraries, because the XCFrameworks aren't built for mergeability in this case.
        do {
            let runDestination = RunDestinationInfo.iOSSimulator
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "ARCHS": "arm64",
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            //let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
            let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
            let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(fwkBaseName).xcframework", "--platform", "ios", "--environment", "simulator", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }
                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(libBaseName).xcframework", "--platform", "ios", "--environment", "simulator", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }

                results.checkTarget("App") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    let INSTALL_PATH = "/Applications"

                    // Check that we're *not* merging the XCFrameworks during linking.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-framework", "\(fwkBaseName)"],
                            ["-l\(libBaseName)"],
                            ["-o", "\(DSTROOT)/Applications/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                    }

                    // Check that we're copying both the framework and the library appropriately.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["\(fwkXCFrameworkPath.str)/\(iossimLibraryIdentifier)/\(fwkFullProductName)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-exclude_subpath")
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(fwkFullProductName))) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["\(libXCFrameworkPath.str)/\(iossimLibraryIdentifier)/\(libFullProductName)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(libFullProductName))) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)])
                    }

                    results.checkNoDiagnostics()
                }
            }
        }
    }

    /// Test using XCFrameworks with a mergeable framework and library for the macOS.  This is to check that we're using the correct subpaths when copying the framework.
    @Test(.requireSDKs(.macOS))
    func xCFrameworkWithMergeableLibrary_macOS() async throws {

        let CONFIGURATION = "Config"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Framework.xcframework"),
                    TestFile("Dylib.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration(CONFIGURATION, buildSettings: [
                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "MERGE_LINKED_LIBRARIES": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "auto",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(CONFIGURATION),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase([
                            "Framework.xcframework",
                            "Dylib.xcframework",
                        ]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("Framework.xcframework", codeSignOnCopy: true),
                            TestBuildFile("Dylib.xcframework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                    ],
                    dependencies: []
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let infoLookup = try await getCore()

        let macosLibraryIdentifier = "arm64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)"

        let fwkBaseName = "Framework"
        let fwkFullProductName = "\(fwkBaseName).framework"
        let fwkXCFramework = try XCFramework(version: XCFramework.mergeableMetadataVersion, libraries: [
            XCFramework.Library(libraryIdentifier: macosLibraryIdentifier, supportedPlatform: "macos", supportedArchitectures: ["arm64"], platformVariant: nil, libraryPath: Path(fwkFullProductName), binaryPath: Path("\(fwkFullProductName)/Versions/A/\(fwkBaseName)"), headersPath: nil, mergeableMetadata: true),
        ])
        let fwkXCFrameworkPath = Path(SRCROOT).join("\(fwkBaseName).xcframework")
        try fs.createDirectory(fwkXCFrameworkPath, recursive: true)
        try await XCFrameworkTestSupport.writeXCFramework(fwkXCFramework, fs: fs, path: fwkXCFrameworkPath, infoLookup: infoLookup)

        let libBaseName = "Dylib"
        let libFullProductName = "lib\(libBaseName).dylib"
        let libXCFramework = try XCFramework(version: XCFramework.mergeableMetadataVersion, libraries: [
            XCFramework.Library(libraryIdentifier: macosLibraryIdentifier, supportedPlatform: "macos", supportedArchitectures: ["arm64"], platformVariant: nil, libraryPath: Path(libFullProductName), binaryPath: Path("\(libFullProductName)"), headersPath: nil, mergeableMetadata: true),
        ])
        let libXCFrameworkPath = Path(SRCROOT).join("\(libBaseName).xcframework")
        try fs.createDirectory(libXCFrameworkPath, recursive: true)
        try await XCFrameworkTestSupport.writeXCFramework(libXCFramework, fs: fs, path: libXCFrameworkPath, infoLookup: infoLookup)

        // Check a debug build for macOS, where we reexport the XCFrameworks.
        do {
            let runDestination = RunDestinationInfo.macOS
            let buildType = "Debug"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "ARCHS": "arm64",
                "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                "GCC_OPTIMIZATION_LEVEL": "0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ])
            let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
            let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
            let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(fwkBaseName).xcframework", "--platform", "macos", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }
                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(libBaseName).xcframework", "--platform", "macos", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }

                results.checkTarget("App") { target in
                    let targetName = target.target.name
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    // Check that we're merging the XCFramework during linking.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-no_merge_framework", "-Xlinker", "\(fwkBaseName)"],
                            ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))
                    }

                    // Check that we're copying the framework twice, once with its binary and once without.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks/\(fwkFullProductName)")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)"],
                            ["\(fwkXCFrameworkPath.str)/\(macosLibraryIdentifier)/\(fwkFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks/\(fwkFullProductName)")) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks/\(fwkFullProductName)")])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries/\(fwkFullProductName)")) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)",
                             "-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)_CodeSignature",
                             "-include_only_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)Info.plist",
                             "-include_only_subpath", "\(fwkBaseName)",
                             "-include_only_subpath", "Versions/Current",
                            ],
                            ["-strip_subpath", "\(fwkFullProductName)/\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)"],
                            ["\(BUILT_PRODUCTS_DIR)/\(fwkFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries"]
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries/\(fwkFullProductName)")) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries/\(fwkFullProductName)")])
                    }

                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName))
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(fwkFullProductName))

                    // Check that we're copying the library only once.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)) { task in
                        task.checkCommandLineContains([
                            ["builtin-copy"],
                            ["-strip_subpath", "\(libFullProductName)"],
                            ["\(BUILT_PRODUCTS_DIR)/\(libFullProductName)", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)ReexportedBinaries"]
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-exclude_subpath")
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(libFullProductName))) { task in
                        results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName)])
                    }

                    results.checkNoDiagnostics()
                }
            }
        }

        // Check a release build for macOS, where we merge the XCFrameworks.
        do {
            let runDestination = RunDestinationInfo.macOS
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "ARCHS": "arm64",
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""
            let APP_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Contents/" : ""
            let APP_EXEC_DIR_SUBPATH = runDestination == .macOS ? "\(APP_CONTENTS_DIR_SUBPATH)MacOS/" : ""
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes()

                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(fwkBaseName).xcframework", "--platform", "macos", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }
                results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/\(libBaseName).xcframework", "--platform", "macos", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                }

                results.checkTarget("App") { target in
                    // Check that we're merging the XCFramework during linking.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        let targetName = target.target.name
                        let FULL_PRODUCT_NAME = "\(targetName).app"
                        let INSTALL_PATH = "/Applications"
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-merge_framework", "-Xlinker", "\(fwkBaseName)"],
                            ["-Xlinker", "-merge-l\(libBaseName)"],
                            ["-o", "\(DSTROOT)/Applications/\(FULL_PRODUCT_NAME)/\(APP_EXEC_DIR_SUBPATH)\(targetName)"],
                        ].reduce([], +))

                        // Check that we're copying the framework appropriately.
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", "\(FWK_CONTENTS_DIR_SUBPATH)\(fwkBaseName)"],
                                ["\(fwkXCFrameworkPath.str)/\(macosLibraryIdentifier)/\(fwkFullProductName)", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(APP_CONTENTS_DIR_SUBPATH)Frameworks"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-strip_subpath")
                            results.checkTaskFollows(task, [.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")])
                        }
                        let signedDir = fwkFullProductName
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix(signedDir))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(fwkFullProductName)])
                        }

                        // Check that we're not copying the dylib at all.
                        results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(libFullProductName))
                    }

                    results.checkNoDiagnostics()
                }
            }
        }
    }

    /// Test automatically creating a merged framework via setting `MERGED_BINARY_TYPE = manual`, so that only its dependencies which have `MERGEABLE_LIBRARY` set will be merged/reexported.
    @Test(.requireSDKs(.iOS))
    func manualMergedFrameworkCreation() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("Application.swift"),

                    // Mergeable framework and library sources
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                // App target
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGED_BINARY_TYPE": "manual",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Application.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "MergeableFwkTarget.framework",
                            "NormalFwkTarget.framework",
                        ]),
                        // Embed
                        TestCopyFilesBuildPhase([
                            TestBuildFile("MergeableFwkTarget.framework", codeSignOnCopy: true),
                            TestBuildFile("NormalFwkTarget.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                    ]
                ),
                // Mergeable framework target
                TestStandardTarget(
                    "MergeableFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGEABLE_LIBRARY": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
                // Not-mergeable framework target
                TestStandardTarget(
                    "NormalFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Test a debug build.  This will reexport the mergeable framework and not the normal framework.
        do {
            let buildType = "Debug"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: "Config", overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                "GCC_OPTIMIZATION_LEVEL": "0",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            ])
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: .iOS, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the framework targets were *not* build to be mergeable.
                for targetName in ["MergeableFwkTarget", "NormalFwkTarget"] {
                    results.checkTarget(targetName) { target in
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                            task.checkRuleInfo(["Ld", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(targetName)", "normal"])
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-o", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(targetName)"],
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-make_mergeable")      // Not passed in debug builds
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                        results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                    }
                }

                // Check that the app target handled each framework appropriately.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-no_merge_framework", "-Xlinker", "MergeableFwkTarget",
                             "-framework", "NormalFwkTarget",
                            ],
                            ["-o", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-merge_framework")
                        results.checkTaskFollows(task, [.matchTargetName("MergeableFwkTarget"), .matchRuleType("Ld")])
                        results.checkTaskFollows(task, [.matchTargetName("NormalFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that the frameworks are being embedded.
                    // Also check the reexported framework is having its binary embedded.
                    do {
                        let fwkTargetName = "MergeableFwkTarget"

                        // Check embedding the binary-less framework.
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("Frameworks/\(fwkTargetName).framework"))) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["\(SYMROOT)/Config-iphoneos/\(fwkTargetName).framework", "\(SYMROOT)/Config-iphoneos/\(targetName).app/Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix("Frameworks/\(fwkTargetName).framework"))) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("Frameworks/\(fwkTargetName).framework"))])
                        }

                        // Check embedding the binary-only framework.
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework"))) { task in
                            task.checkRuleInfo(["Copy", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework", "\(SYMROOT)/Config-iphoneos/\(fwkTargetName).framework"])
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-include_only_subpath", fwkTargetName,
                                 "-include_only_subpath", "_CodeSignature",
                                ],
                                ["\(SYMROOT)/Config-iphoneos/\(fwkTargetName).framework", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(reexportedBinariesDirectoryName)"],
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix("\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework"))) { task in
                            task.checkRuleInfo(["CodeSign", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework"])
                            task.checkCommandLineContains(["/usr/bin/codesign", "--preserve-metadata=identifier,entitlements,flags", "\(SYMROOT)/Config-iphoneos/\(targetName).app/\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework"])
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework"))])
                        }
                    }
                    do {
                        let fwkTargetName = "NormalFwkTarget"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["\(SYMROOT)/Config-iphoneos/\(fwkTargetName).framework", "\(SYMROOT)/Config-iphoneos/\(targetName).app/Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")])
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }

        // Test a release build.  This will build the mergeable targets to be mergeable, and merge them into the top-level framework.
        do {
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let parameters = BuildParameters(configuration: "Config", overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: .iOS, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check that the mergeable targets were *not* built to be mergeable.
                results.checkTarget("MergeableFwkTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(DSTROOT)/Library/Frameworks/\(targetName).framework/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-make_mergeable"],
                            ["-o", "\(DSTROOT)/Library/Frameworks/\(targetName).framework/\(targetName)"],
                        ].reduce([], +))
                    }
                    // Don't generate an intermediate .tbd file for eager linking when we're making the binary mergeable.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                    // Mergeable products should not be stripped.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }
                results.checkTarget("NormalFwkTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(DSTROOT)/Library/Frameworks/\(targetName).framework/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-o", "\(DSTROOT)/Library/Frameworks/\(targetName).framework/\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-make_mergeable")
                    }
                    // Check tasks are being run for this normal framework target.
                    results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(DSTROOT)/Applications/\(targetName).app/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-merge_framework", "-Xlinker", "MergeableFwkTarget",
                             "-framework", "NormalFwkTarget",
                            ],
                            ["-o", "\(DSTROOT)/Applications/\(targetName).app/\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-no_merge_framework")
                        results.checkTaskFollows(task, [.matchTargetName("MergeableFwkTarget"), .matchRuleType("Ld")])
                        results.checkTaskFollows(task, [.matchTargetName("NormalFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that we are removing the binary from the mergeable framework (because they got merged into the merged framework), but we're not doing do for the normal framework..
                    do {
                        let fwkTargetName = "MergeableFwkTarget"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", fwkTargetName],
                                ["\(SYMROOT)/Config-iphoneos/\(fwkTargetName).framework", "\(DSTROOT)/Applications/\(targetName).app/Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")])
                        }
                    }
                    do {
                        let fwkTargetName = "NormalFwkTarget"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["\(SYMROOT)/Config-iphoneos/\(fwkTargetName).framework", "\(DSTROOT)/Applications/\(targetName).app/Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")])
                        }
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test how `dsymutil` is invoked on a merged binary. This involves passing `-D` options to directories where the mergeable libraries' dSYMs were generated, and also passing `-build-variant-suffix=_<variant>` for non-normal build variants.
    @Test(.requireSDKs(.iOS))
    func mergedBinaryDSYMCreation() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("Application.swift"),

                    // Mergeable framework sources
                    TestFile("ClassOne.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                // App target
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGED_BINARY_TYPE": "automatic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Application.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "MergeableFwkTarget.framework",
                        ]),
                        // Embed
                        TestCopyFilesBuildPhase([
                            TestBuildFile("MergeableFwkTarget.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                    ]
                ),
                // Mergeable framework target
                TestStandardTarget(
                    "MergeableFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Test a release build.  This will build the dependency to be mergeable, and merge it into the top-level framework.
        do {
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let CONFIGURATION = "Config"
            let buildVariants = ["normal", "profile"]
            let runDestination = RunDestinationInfo.iOS
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
                "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                "BUILD_VARIANTS": buildVariants.joined(separator: " "),
            ])
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
            let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: .iOS, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check the mergeable target.
                results.checkTarget("MergeableFwkTarget") { target in
                    let targetName = target.target.name
                    let INSTALL_PATH = "/Library/Frameworks"
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    for variant in buildVariants {
                        let variantSuffix = (variant == "normal" ? "" : "_\(variant)")
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem(variant)) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-Xlinker", "-make_mergeable"],
                                ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(targetName)\(variantSuffix)"],
                            ].reduce([], +))
                        }

                        results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("\(targetName)\(variantSuffix)")) { task in
                            task.checkCommandLineContains([
                                ["dsymutil"],
                                ["\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(targetName)\(variantSuffix)"],
                                ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME).dSYM"],
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-D")
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    let INSTALL_PATH = "/Applications"
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    for variant in buildVariants {
                        let variantSuffix = (variant == "normal" ? "" : "_\(variant)")
                        results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem(variant)) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-Xlinker", "-merge_framework", "-Xlinker", "MergeableFwkTarget"],
                                ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(targetName)\(variantSuffix)"],
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-no_merge_framework")
                            results.checkTaskFollows(task, [.matchTargetName("MergeableFwkTarget"), .matchRuleType("Ld"), .matchRuleItem(variant)])
                        }

                        results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("\(targetName)\(variantSuffix)")) { task in
                            task.checkCommandLineContains([
                                ["dsymutil"],
                                // This test basically exists to check that the next two options being passed as appropriate.
                                (variant == "normal" ? [] : ["-build-variant-suffix=\(variantSuffix)"]),
                                ["-D", "\(BUILT_PRODUCTS_DIR)"],
                                ["\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(targetName)\(variantSuffix)"],
                                ["-o", "\(BUILT_PRODUCTS_DIR)/\(FULL_PRODUCT_NAME).dSYM"],
                            ].reduce([], +))
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Confirm that when mergeable library targets of a merged binary target depends on other targets that they are not accidentally treated as mergeable libraries themselves in unexpected ways.
    @Test(.requireSDKs(.iOS))
    func dependenciesOfMergeableLibraryTargets() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("Application.swift"),

                    // Framework sources
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                // App target, which automatically builds its dependencies and mergeable and then merges them.
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGED_BINARY_TYPE": "automatic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Application.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "MergeableFwkTarget.framework",
                        ]),
                        // Embed
                        TestCopyFilesBuildPhase([
                            TestBuildFile("MergeableFwkTarget.framework", codeSignOnCopy: true),
                            TestBuildFile("NormalFwkTarget.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                    ]
                ),
                // Mergeable framework target which is merged into the app target.
                TestStandardTarget(
                    "MergeableFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "NormalFwkTarget.framework",
                        ]),
                    ]
                ),
                // Non-mergeable framework target, which the mergeable framework target depends on, but which is not merged.
                TestStandardTarget(
                    "NormalFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Test a release build.
        do {
            let buildType = "Release"
            let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
            let CONFIGURATION = "Config"
            let runDestination = RunDestinationInfo.iOS
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            ])
            let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
            let targets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            await tester.checkBuild(parameters, runDestination: .iOS, buildRequest: request) { results in
                results.consumeTasksMatchingRuleTypes()

                // Check the normal framework target.
                results.checkTarget("NormalFwkTarget") { target in
                    let targetName = target.target.name
                    let INSTALL_PATH = "/Library/Frameworks"
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(targetName)"],
                        ].reduce([], +))
                        task.checkCommandLineDoesNotContain("-make_mergeable")
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the mergeable target.
                results.checkTarget("MergeableFwkTarget") { target in
                    let targetName = target.target.name
                    let INSTALL_PATH = "/Library/Frameworks"
                    let FULL_PRODUCT_NAME = "\(targetName).framework"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-make_mergeable"],
                            ["-framework", "NormalFwkTarget"],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(targetName)"],
                        ].reduce([], +))
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check the app target.
                results.checkTarget("AppTarget") { target in
                    let targetName = target.target.name
                    let INSTALL_PATH = "/Applications"
                    let FULL_PRODUCT_NAME = "\(targetName).app"
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-Xlinker", "-merge_framework", "-Xlinker", "MergeableFwkTarget"],
                            ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(targetName)"],
                        ].reduce([], +))
                        results.checkTaskFollows(task, [.matchTargetName("MergeableFwkTarget"), .matchRuleType("Ld")])
                    }

                    // Check that the mergeable framework is embedded without its binary.
                    do {
                        let fwkTargetName = "MergeableFwkTarget"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["-exclude_subpath", fwkTargetName],
                                ["\(BUILT_PRODUCTS_DIR)/\(fwkTargetName).framework", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            // --generate-pre-encrypt-hashes is added dynamically in CodeSignTaskAction and is checked in MergeableLibrariesBuildOperationTests.testAutomaticMergedFrameworkCreation()
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")])
                        }
                    }

                    // Check that the normal framework is embedded with its binary.
                    do {
                        let fwkTargetName = "NormalFwkTarget"
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            task.checkCommandLineContains([
                                ["builtin-copy"],
                                ["\(BUILT_PRODUCTS_DIR)/\(fwkTargetName).framework", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/Frameworks"]
                            ].reduce([], +))
                            results.checkTaskFollows(task, [.matchTargetName(fwkTargetName), .matchRuleType("Touch")])
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                            results.checkTaskFollows(task, [.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")])
                        }
                    }

                    results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that a target which creates a mergeable library but which itself has no sources.
    ///
    /// Specific scenarios:
    /// 1. Creates a library when doing a normal build.
    /// 2. Does not create a library for other build components, such as headers and api.
    ///
    /// - remark: `testAutomaticMergedFrameworkCreation_iOS()` also exercises the normal build workflow for this.
    @Test(.requireSDKs(.iOS))
    func mergeableLibraryWithNoSources() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // Mergeable framework sources
                    TestFile("ClassOne.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SUPPORTS_TEXT_BASED_API": "YES",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                // Merged framework target
                TestStandardTarget(
                    "MergedFwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGED_BINARY_TYPE": "automatic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            // Intentionally empty
                        ]),
                        TestFrameworksBuildPhase([
                            "FwkTarget1.framework",
                        ]),
                    ],
                    // We want to test both explicit and implicit dependencies so not all targets are listed here.
                    dependencies: ["FwkTarget1"]
                ),
                // Mergeable framework target
                TestStandardTarget(
                    "FwkTarget1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let runDestination = RunDestinationInfo.iOS
        let CONFIGURATION = "Config"
        let FWK_CONTENTS_DIR_SUBPATH = runDestination == .macOS ? "Versions/A/" : ""

        // Test a release build, since we're mainly interested in the install workflows here.
        do {
            for action: BuildAction in [.install, .installHeaders, .installAPI] {
                let buildType = "Release"
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
                let parameters = BuildParameters(action: action, configuration: CONFIGURATION, overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                    "GCC_OPTIMIZATION_LEVEL": "s",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                ])
                // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request) { results in
                    results.consumeTasksMatchingRuleTypes()

                    // Check the actions with a build component.
                    if action.buildComponents.contains("build") {
                        // Check that the mergeable targets were built to be mergeable.
                        for targetName in ["FwkTarget1"] {
                            let FULL_PRODUCT_NAME = "\(targetName).framework"
                            let INSTALL_PATH = "/Library/Frameworks"
                            results.checkTarget(targetName) { target in
                                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                                    task.checkCommandLineContains([
                                        ["clang"],
                                        ["-Xlinker", "-make_mergeable"],
                                        ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                                    ].reduce([], +))
                                }

                                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                            }
                        }

                        // Check that the merged framework was built with -merge_framework.
                        results.checkTarget("MergedFwkTarget") { target in
                            let targetName = target.target.name
                            let FULL_PRODUCT_NAME = "\(targetName).framework"
                            let INSTALL_PATH = "/Library/Frameworks"
                            results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                                task.checkCommandLineContains([
                                    ["clang"],
                                    ["-Xlinker", "-merge_framework", "-Xlinker", "FwkTarget1",
                                    ],
                                    ["-o", "\(DSTROOT)\(INSTALL_PATH)/\(FULL_PRODUCT_NAME)/\(FWK_CONTENTS_DIR_SUBPATH)\(targetName)"],
                                ].reduce([], +))
                                task.checkCommandLineDoesNotContain("-no_merge_framework")
                                results.checkTaskFollows(task, [.matchTargetName("FwkTarget1"), .matchRuleType("Ld")])
                            }
                            results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }

                            // Check that we're not embedding the binaries into this target, because this is not the debug/reexport workflow.
                            for mergeableTargetProductName in ["FwkTarget1.framework"] {
                                results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename(mergeableTargetProductName))
                            }

                            results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                        }
                    }
                    // Check the other actions.
                    else {
                        // Check that the mergeable targets were built to be mergeable.
                        for targetName in ["FwkTarget1"] {
                            results.checkTarget(targetName) { target in
                                results.checkNoTask(.matchTarget(target), .matchRuleType("Ld"))

                                if action.buildComponents.contains("api") {
                                    results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }
                                }

                                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                            }
                        }

                        // Check that the merged framework was built with -merge_framework.
                        results.checkTarget("MergedFwkTarget") { target in
                            let targetName = target.target.name
                            // The main thing we're testing here: That there is no link task for the non-build actions.
                            results.checkNoTask(.matchTarget(target), .matchRuleType("Ld"))

                            // Check that we're not embedding the binaries into this target, because this is not the debug/reexport workflow.
                            for mergeableTargetProductName in ["FwkTarget1.framework"] {
                                results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename(mergeableTargetProductName))
                            }

                            results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
                        }
                    }

                    // Check there are no other targets.
                    #expect(results.otherTargets == [])

                    // There shouldn't be any diagnostics.
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    /// Test that we see the expected errors if trying to use mergeable libraries for unsupported architectures.
    @Test(.requireSDKs(.watchOS))
    func unsupportedArchitectureErrors() async throws {

        // Our test project exercised both the automatic and the manual workflows.
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("AutomaticApp.swift"),
                    TestFile("ManualApp.swift"),
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "ARCHS[sdk=watchos*]": "arm64 ar64_32 armv7k",
                        "ARCHS[sdk=watchsimulator*]": "i386 arm64",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                // Automatic merged framework target
                TestStandardTarget(
                    "AutomaticApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "AUTOMATICALLY_MERGE_DEPENDENCIES": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AutomaticApp.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "AutomaticMergeableFwk.framework",
                        ]),
                        // Embed
                        TestCopyFilesBuildPhase([
                            TestBuildFile("AutomaticMergeableFwk.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                    ],
                    // We want to test both explicit and implicit dependencies so not all targets are listed here.
                    dependencies: ["AutomaticMergeableFwk"]
                ),
                // Automatic mergeable framework target
                TestStandardTarget(
                    "AutomaticMergeableFwk",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "SKIP_INSTALL": "YES",
                                               ]
                                              ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
                // Manual merged framework target
                TestStandardTarget(
                    "ManualApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGE_LINKED_LIBRARIES": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ManualApp.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "ManualMergeableFwk.framework",
                        ]),
                        // Embed
                        TestCopyFilesBuildPhase([
                            TestBuildFile("ManualMergeableFwk.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                    ],
                    // We want to test both explicit and implicit dependencies so not all targets are listed here.
                    dependencies: ["ManualMergeableFwk"]
                ),
                // Manual mergeable framework target
                TestStandardTarget(
                    "ManualMergeableFwk",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                                               buildSettings: [
                                                "MERGEABLE_LIBRARY": "YES",
                                                "SKIP_INSTALL": "YES",
                                               ]
                                              ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let project = tester.workspace.projects[0]

        // Exercise the two scenarios using architectures we know are not supported.
        do {
            let runDestination = RunDestinationInfo(platform: "watchos", sdk: "watchos", sdkVariant: "watchos", targetArchitecture: "armv7k", supportedArchitectures: ["armv7k"], disableOnlyActiveArch: false)

            // Test a debug build
            do {
                let (SYMROOT, OBJROOT, DSTROOT) = ("/tmp/buildDir/\(runDestination.platform)/sym", "/tmp/buildDir/\(runDestination.platform)/obj", "/tmp/buildDir/\(runDestination.platform)/dst")
                let parameters = BuildParameters(configuration: "Config", overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                    "GCC_OPTIMIZATION_LEVEL": "0",
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                ])
                // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request) { results in
                    results.checkError("Mergeable libraries are not supported for architecture 'armv7k', but AUTOMATICALLY_MERGE_DEPENDENCIES is assigned at level: target. (in target 'AutomaticApp' from project 'aProject')")
                    results.checkError("Mergeable libraries are not supported for architecture 'armv7k', but MERGE_LINKED_LIBRARIES is assigned at level: target. (in target 'ManualApp' from project 'aProject')")
                    results.checkError("Mergeable libraries are not supported for architecture 'armv7k', but MERGEABLE_LIBRARY is assigned at level: target. (in target 'ManualMergeableFwk' from project 'aProject')")

                    for targetName in project.targets.map({ $0.name }) {
                        results.checkWarning("The armv7k architecture is deprecated for your deployment target (watchOS \(results.runDestinationSDK.defaultDeploymentTarget)). You should update your ARCHS build setting to remove the armv7k architecture. (in target '\(targetName)' from project 'aProject')")
                    }

                    // There shouldn't be any other diagnostics.
                    results.checkNoDiagnostics()
                }
            }

            // Test a release build
            do {
                let (SYMROOT, OBJROOT, DSTROOT) = ("/tmp/buildDir/\(runDestination.platform)/sym", "/tmp/buildDir/\(runDestination.platform)/obj", "/tmp/buildDir/\(runDestination.platform)/dst")
                let parameters = BuildParameters(configuration: "Config", overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                    "GCC_OPTIMIZATION_LEVEL": "s",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                ])
                // Add all the targets as top-level targets as this can shake out certain kinds of target dependency resolution bugs.
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                await tester.checkBuild(parameters, runDestination: runDestination, buildRequest: request) { results in
                    results.checkError("Mergeable libraries are not supported for architecture 'armv7k', but AUTOMATICALLY_MERGE_DEPENDENCIES is assigned at level: target. (in target 'AutomaticApp' from project 'aProject')")
                    results.checkError("Mergeable libraries are not supported for architecture 'armv7k', but MERGE_LINKED_LIBRARIES is assigned at level: target. (in target 'ManualApp' from project 'aProject')")
                    results.checkError("Mergeable libraries are not supported for architecture 'armv7k', but MERGEABLE_LIBRARY is assigned at level: target. (in target 'ManualMergeableFwk' from project 'aProject')")

                    for targetName in project.targets.map({ $0.name }) {
                        results.checkWarning("The armv7k architecture is deprecated for your deployment target (watchOS \(results.runDestinationSDK.defaultDeploymentTarget)). You should update your ARCHS build setting to remove the armv7k architecture. (in target '\(targetName)' from project 'aProject')")
                    }

                    // There shouldn't be any other diagnostics.
                    results.checkNoDiagnostics()
                }
            }
        }
    }

}
