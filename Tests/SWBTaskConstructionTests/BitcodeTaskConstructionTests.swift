//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
import SWBTestSupport

import SWBCore
import SWBUtil

/// Test task construction involving bitcode.
///
/// Bitcode has a complicated set of rules including multiple generation modes (off, marker, full), and affects compiling, linking, and copying.
@Suite(.userDefaults(["EnableBitcodeSupport": "1"]))
fileprivate struct BitcodeTaskConstructionTests: CoreBasedTests {
    /// Test the logic to strip bitcode when copying items in a copy files build phase.
    @Test(.requireSDKs(.iOS))
    func bitcodeStripWhileCopying() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("AppSource.m"),
                    TestFile("FwkSource.m"),
                    TestFile("Info.plist"),
                    TestFile("Mock.txt"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration( "Debug", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                    // Using the public iOS SDK defaults both ENABLE_BITCODE and STRIP_BITCODE_FROM_COPIED_FILES to YES.
                    "SDKROOT": "iphoneos",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppSource.m",
                        ]),
                        TestFrameworksBuildPhase([]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("FwkTarget.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("Mock.txt", codeSignOnCopy: true),
                        ], destinationSubfolder: .resources, onlyForDeployment: false),
                    ],
                    dependencies: ["FwkTarget"]
                ),
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "FwkSource.m",
                        ]),
                        TestFrameworksBuildPhase([]),
                    ]
                ),
            ]
        )

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Test building without bitcode.
        await tester.checkBuild(BuildParameters(configuration: "Debug", activeRunDestination: .iOS, overrides: ["ENABLE_BITCODE": "NO", "BITCODE_GENERATION_MODE": "bitcode"])) { results in
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check that none of the bitcode options are in the compile and link tasks' command lines.
            results.checkTasks(.matchRuleType("CompileC")) { tasks in
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    task.checkCommandLineDoesNotContain("-fembed-bitcode")
                }
            }
            results.checkTasks(.matchRuleType("Ld")) { tasks in
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    task.checkCommandLineDoesNotContain("-fembed-bitcode")
                    task.checkCommandLineDoesNotContain("-bitcode_verify")
                    task.checkCommandLineDoesNotContain("-bitcode_hide_symbols")
                    task.checkCommandLineDoesNotContain("-bitcode_symbol_map")
                }
            }

            // Check that the copying of the framework is stripping bitcode fully.
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                task.checkCommandLineContainsUninterrupted(["-bitcode-strip", "all", "-bitcode-strip-tool", "\(core.developerPath.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/bitcode_strip"])
                task.checkCommandLineContainsUninterrupted(["\(SRCROOT)/build/Debug-iphoneos/FwkTarget.framework", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks"])
            }
            // Check that the copying of the text file is NOT stripping bitcode (because this file is not code signed and so should never be stripped).
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItemBasename("Mock.txt")) { task in
                task.checkCommandLineDoesNotContain("-bitcode-strip")
                task.checkCommandLineDoesNotContain("-bitcode-strip-tool")
                task.checkCommandLineContainsUninterrupted(["\(SRCROOT)/Mock.txt", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app"])
            }
        }

        // Test building with the bitcode marker.
        await tester.checkBuild(BuildParameters(configuration: "Debug", activeRunDestination: .iOS, overrides: ["ENABLE_BITCODE": "YES", "BITCODE_GENERATION_MODE": "marker"])) { results in
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'AppTarget' from project 'aProject')"))
            results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'FwkTarget' from project 'aProject')"))

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check that none of the bitcode options are in the compile and link tasks' command lines.
            results.checkTasks(.matchRuleType("CompileC")) { tasks in
                for task in tasks {
                    task.checkCommandLineContains(["-fembed-bitcode-marker"])
                    task.checkCommandLineDoesNotContain("-fembed-bitcode")
                }
            }
            results.checkTasks(.matchRuleType("Ld")) { tasks in
                for task in tasks {
                    task.checkCommandLineContains(["-fembed-bitcode-marker"])
                    task.checkCommandLineDoesNotContain("-fembed-bitcode")
                    task.checkCommandLineDoesNotContain("-bitcode_verify")
                    task.checkCommandLineDoesNotContain("-bitcode_hide_symbols")
                    task.checkCommandLineDoesNotContain("-bitcode_symbol_map")
                }
            }

            // Check that the copying of the framework is stripping bitcode to marker level.
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                task.checkCommandLineContainsUninterrupted(["-bitcode-strip", "replace-with-marker", "-bitcode-strip-tool", "\(core.developerPath.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/bitcode_strip"])
                task.checkCommandLineContainsUninterrupted(["\(SRCROOT)/build/Debug-iphoneos/FwkTarget.framework", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks"])
            }
            // Check that the copying of the text file is NOT stripping bitcode (because this file is not code signed and so should never be stripped).
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItemBasename("Mock.txt")) { task in
                task.checkCommandLineDoesNotContain("-bitcode-strip")
                task.checkCommandLineDoesNotContain("-bitcode-strip-tool")
                task.checkCommandLineContainsUninterrupted(["\(SRCROOT)/Mock.txt", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app"])
            }
        }

        // Test building with full bitcode.
        await tester.checkBuild(BuildParameters(configuration: "Debug", activeRunDestination: .iOS, overrides: ["ENABLE_BITCODE": "YES", "BITCODE_GENERATION_MODE": "bitcode"])) { results in
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'AppTarget' from project 'aProject')"))
            results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'FwkTarget' from project 'aProject')"))

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check that none of the bitcode options are in the compile and link tasks' command lines.
            results.checkTasks(.matchRuleType("CompileC")) { tasks in
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    task.checkCommandLineContains(["-fembed-bitcode"])
                }
            }
            results.checkTasks(.matchRuleType("Ld")) { tasks in
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    task.checkCommandLineContains(["-fembed-bitcode"])
                    task.checkCommandLineContains(["-bitcode_verify", "-bitcode_hide_symbols", "-bitcode_symbol_map"])
                }
            }

            // Check that the copying of the framework is NOT stripping bitcode (because we're building for full bitcode).
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                task.checkCommandLineDoesNotContain("-bitcode-strip")
                task.checkCommandLineDoesNotContain("-bitcode-strip-tool")
                task.checkCommandLineContainsUninterrupted(["\(SRCROOT)/build/Debug-iphoneos/FwkTarget.framework", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks"])
            }
            // Check that the copying of the text file is NOT stripping bitcode (because this file is not code signed and so should never be stripped).
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItemBasename("Mock.txt")) { task in
                task.checkCommandLineDoesNotContain("-bitcode-strip")
                task.checkCommandLineDoesNotContain("-bitcode-strip-tool")
                task.checkCommandLineContainsUninterrupted(["\(SRCROOT)/Mock.txt", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app"])
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func bitcodeSymbolsAreNotHiddenInMHObjectProducts() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("AppSource.m"),
                    TestFile("LibSource.m"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                    // Using the public iOS SDK defaults both ENABLE_BITCODE and STRIP_BITCODE_FROM_COPIED_FILES to YES.
                    "SDKROOT": "iphoneos",
                    "ENABLE_BITCODE": "YES",
                    "BITCODE_GENERATION_MODE": "bitcode",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_NAME": "App",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppSource.m",
                        ]),
                        TestFrameworksBuildPhase([
                            "Lib.o"
                        ]),
                    ],
                    dependencies: ["Lib"]
                ),
                TestStandardTarget(
                    "Lib",
                    type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "Lib",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "LibSource.m",
                        ]),
                        TestFrameworksBuildPhase([]),
                    ]
                ),
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", activeRunDestination: .iOS)) { results in
            results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'App' from project 'aProject')"))
            results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'Lib' from project 'aProject')"))

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check that none of the bitcode options are in the compile and link tasks' command lines.
            results.checkTasks(.matchRuleType("CompileC")) { tasks in
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    task.checkCommandLineContains(["-fembed-bitcode"])
                }
            }
            results.checkTasks(.matchTargetName("Lib"), .matchRuleType("Ld")) { tasks in
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    task.checkCommandLineContains(["-fembed-bitcode"])
                    task.checkCommandLineContains(["-bitcode_verify"])
                    task.checkCommandLineDoesNotContain("-bitcode_hide_symbols")
                    task.checkCommandLineDoesNotContain("-bitcode_symbol_map")
                }
            }
            results.checkTasks(.matchTargetName("App"), .matchRuleType("Ld")) { tasks in
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    task.checkCommandLineContains(["-fembed-bitcode"])
                    task.checkCommandLineContains(["-bitcode_verify"])
                    task.checkCommandLineContains(["-bitcode_hide_symbols"])
                    task.checkCommandLineContains(["-bitcode_symbol_map"])
                }
            }
        }
    }

    func _testBitcodeFlags(sdkroot: String, expectBitcode: Bool) async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("FwkSource.m"),
                    TestFile("FwkSource.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": sdkroot,
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "EXCLUDED_SOURCE_FILE_NAMES[sdk=driverkit*]": "*.swift",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "FwkSource.m",
                            "FwkSource.swift",
                        ]),
                    ]
                ),
            ]
        )
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Test building with the bitcode marker.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_BITCODE": "YES", "BITCODE_GENERATION_MODE": "marker"]), runDestination: nil) { results in
            if expectBitcode {
                results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'FwkTarget' from project 'aProject')"))
            }

            results.checkNoDiagnostics()

            results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { tasks in
                if sdkroot != "driverkit" {
                    #expect(tasks.count > 0)
                }
                for task in tasks {
                    let arch = task.ruleInfo[safe: task.ruleInfo.count - 2]
                    if expectBitcode && arch != "i386" && arch != "x86_64" {
                        task.checkCommandLineContains(["-embed-bitcode-marker"])
                    } else {
                        task.checkCommandLineDoesNotContain("-embed-bitcode-marker")
                    }
                    task.checkCommandLineDoesNotContain("-embed-bitcode")
                }
            }
            results.checkTasks(.matchRuleType("CompileC")) { tasks in
                #expect(tasks.count > 0)
                for task in tasks {
                    let arch = task.ruleInfo[safe: 4]
                    if expectBitcode && arch != "i386" && arch != "x86_64" {
                        task.checkCommandLineContains(["-fembed-bitcode-marker"])
                    } else {
                        task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    }
                    task.checkCommandLineDoesNotContain("-fembed-bitcode")
                }
            }
            results.checkTasks(.matchRuleType("Ld")) { tasks in
                #expect(tasks.count > 0)
                for task in tasks {
                    if expectBitcode {
                        task.checkCommandLineContains(["-fembed-bitcode-marker"])
                    } else {
                        task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    }
                    task.checkCommandLineDoesNotContain("-fembed-bitcode")
                    task.checkCommandLineDoesNotContain("-bitcode_verify")
                    task.checkCommandLineDoesNotContain("-bitcode_hide_symbols")
                    task.checkCommandLineDoesNotContain("-bitcode_symbol_map")
                }
            }
        }

        // Test building with full bitcode.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_BITCODE": "YES", "BITCODE_GENERATION_MODE": "bitcode"]), runDestination: nil) { results in
            if expectBitcode {
                results.checkWarning(.equal("Building with bitcode is deprecated. Please update your project and/or target settings to disable bitcode. (in target 'FwkTarget' from project 'aProject')"))
            }

            results.checkNoDiagnostics()

            results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { tasks in
                if sdkroot != "driverkit" {
                    #expect(tasks.count > 0)
                }
                for task in tasks {
                    let arch = task.ruleInfo[safe: task.ruleInfo.count - 2]
                    if expectBitcode && arch != "i386" && arch != "x86_64" {
                        task.checkCommandLineContains(["-embed-bitcode"])
                    } else {
                        task.checkCommandLineDoesNotContain("-embed-bitcode")
                    }
                    task.checkCommandLineDoesNotContain("-embed-bitcode-marker")
                }
            }
            results.checkTasks(.matchRuleType("CompileC")) { tasks in
                #expect(tasks.count > 0)
                for task in tasks {
                    let arch = task.ruleInfo[safe: 4]
                    if expectBitcode && arch != "i386" && arch != "x86_64" {
                        task.checkCommandLineContains(["-fembed-bitcode"])
                    } else {
                        task.checkCommandLineDoesNotContain("-fembed-bitcode")
                    }
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                }
            }
            results.checkTasks(.matchRuleType("Ld")) { tasks in
                #expect(tasks.count > 0)
                for task in tasks {
                    task.checkCommandLineDoesNotContain("-fembed-bitcode-marker")
                    if expectBitcode {
                        task.checkCommandLineContains(["-fembed-bitcode"])
                        task.checkCommandLineContains(["-bitcode_verify", "-bitcode_hide_symbols", "-bitcode_symbol_map"])
                    } else {
                        task.checkCommandLineDoesNotContain("-fembed-bitcode")
                        task.checkCommandLineDoesNotContain("-bitcode_verify")
                        task.checkCommandLineDoesNotContain("-bitcode_hide_symbols")
                        task.checkCommandLineDoesNotContain("-bitcode_symbol_map")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func bitcodeUnsupportedPlatformsIgnored_macOS() async throws {
        try await _testBitcodeFlags(sdkroot: "macosx", expectBitcode: false)
    }

    @Test(.requireSDKs(.driverKit))
    func bitcodeUnsupportedPlatformsIgnored_DriverKit() async throws {
        try await _testBitcodeFlags(sdkroot: "driverkit", expectBitcode: false)
    }

    @Test(.requireSDKs(.iOS))
    func bitcodeUnsupportedPlatformsIgnored_iOSSimulator() async throws {
        try await _testBitcodeFlags(sdkroot: "iphonesimulator", expectBitcode: false)
    }

    @Test(.requireSDKs(.tvOS))
    func bitcodeUnsupportedPlatformsIgnored_tvOSSimulator() async throws {
        try await _testBitcodeFlags(sdkroot: "appletvsimulator", expectBitcode: false)
    }

    @Test(.requireSDKs(.watchOS))
    func bitcodeUnsupportedPlatformsIgnored_watchOSSimulator() async throws {
        try await _testBitcodeFlags(sdkroot: "watchsimulator", expectBitcode: false)
    }

    @Test(.requireSDKs(.iOS))
    func bitcodeSupportedPlatforms_iOS() async throws {
        try await _testBitcodeFlags(sdkroot: "iphoneos", expectBitcode: true)
    }

    @Test(.requireSDKs(.tvOS))
    func bitcodeSupportedPlatforms_tvOS() async throws {
        try await _testBitcodeFlags(sdkroot: "appletvos", expectBitcode: true)
    }

    @Test(.requireSDKs(.watchOS))
    func bitcodeSupportedPlatforms_watchOS() async throws {
        try await _testBitcodeFlags(sdkroot: "watchos", expectBitcode: true)
    }
}
