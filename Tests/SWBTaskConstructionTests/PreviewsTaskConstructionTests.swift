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

import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite(.requireXcode16())
fileprivate struct PreviewsTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func app() async throws {
        let core = try await getCore()

        let archs = ["x86_64", "x86_64h"]

        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "ARCHS": archs.joined(separator: " "),
                            "VALID_ARCHS": "$(inherited) x86_64h",
                            "ENABLE_PREVIEWS": "YES",
                            "INFOPLIST_FILE": "Sources/Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                        ]),
                    ])
            ])
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(runDestination: .anyMac) { results in
            results.checkNoDiagnostics()

            for arch in archs {
                results.checkTask(.matchRule(["SwiftDriver Compilation", "TargetName", "normal", arch, "com.apple.xcode.tools.swift.compiler"])) { task in
                    // Previews need a module
                    task.checkCommandLineContains(["-emit-module"])

                    // Previews need dynamic replacement and private imports
                    task.checkCommandLineContainsUninterrupted(["-Xfrontend", "-enable-implicit-dynamic"])
                    task.checkCommandLineContainsUninterrupted(["-Xfrontend", "-enable-private-imports"])
                    task.checkCommandLineContainsUninterrupted(["-Xfrontend", "-enable-dynamic-replacement-chaining"])
                    task.checkCommandLineContainsUninterrupted(["-Xfrontend", "-disable-previous-implementation-calls-in-dynamic-replacements"])
                }

                // We shouldn't create the framework mode dylib
                results.checkNoTask(.matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName.debug.dylib", "normal", arch]))

                // Ensure that this is not a preview shim
                results.checkTask(.matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName", "normal", arch])) { task in
                    task.checkCommandLineContains(["-filelist"])
                    task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/File1.o")])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func previewsDylibMode() async throws {
        let core = try await getCore()
        let archs = ["x86_64", "x86_64h"]
        let archsJoined = archs.joined(separator: " ")

        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("Info.plist"),
                    TestFile("Entitlements.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                            "SWIFT_VERSION": swiftVersion,
                            "ARCHS": archsJoined,
                            "VALID_ARCHS": "$(inherited) x86_64h",
                            "ENABLE_XOJIT_PREVIEWS": "YES",
                            "ENABLE_DEBUG_DYLIB": "YES",

                            // Added this while the macOS platform is disabled to force building it with the dylib.
                            // Remove with: rdar://122644133 (Re-enable macOS preview dylib mode)
                            "ENABLE_DEBUG_DYLIB_OVERRIDE": "YES",

                            "DEFINES_MODULE": "NO",
                            "INFOPLIST_FILE": "Sources/Info.plist",
                            "CODE_SIGN_ENTITLEMENTS": "Sources/Entitlements.plist",
                            "CODE_SIGN_IDENTITY": "-",
                            "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
                            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                            "LD_RUNPATH_SEARCH_PATHS": "@executable_path/../Frameworks2",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                        ]),
                    ])
            ])
        let tester = try TaskConstructionTester(core, testProject)

        // The localFS is used because we need a value for the swiftlang version in order for
        // -disable-previous-implementation-calls-in-dynamic-replacements to be inserted.
        await tester.checkBuild(runDestination: .anyMac, fs: localFS) { results in
            results.checkNoDiagnostics()

            for arch in archs {
                // Compile tasks

                results.checkTask(.matchRule(["SwiftDriver Compilation", "TargetName", "normal", arch, "com.apple.xcode.tools.swift.compiler"])) { task in
                    // These were necessary for dynamic replacement but _should not_ be in XOJIT previews dylib mode.
                    task.checkCommandLineDoesNotContain("-enable-private-imports")
                    task.checkCommandLineDoesNotContain("-enable-dynamic-replacement-chaining")
                    task.checkCommandLineDoesNotContain("-disable-previous-implementation-calls-in-dynamic-replacements")
                }

                // Empty stub dylib

                results.checkTask(.matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/__preview.dylib", "normal", arch])) { task in
                    task.checkCommandLineContainsUninterrupted(["-install_name", "@rpath/TargetName.debug.dylib"])
                }

                // Preview dylib

                results.checkTask(.matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName.debug.dylib", "normal", arch])) { task in
                    task.checkCommandLineContains(["-dynamiclib"])
                    task.checkCommandLineContains(["-filelist"])
                    task.checkCommandLineContainsUninterrupted(["-install_name", "@rpath/TargetName.debug.dylib"])
                    task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/File1.o")])

                    // The dylib should have the rpaths the app would usually get
                    task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks2"])
                }
            }

            results.checkTask(.matchRule(["CreateUniversalBinary", "/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib", "normal", archsJoined])) { task in
                for arch in archs {
                    task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName.debug.dylib")])
                }
            }

            results.checkTask(.matchRule(["CodeSign", "/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/__preview.dylib"])) { task in
                #expect(!task.inputs.contains { $0.path == Path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName.app.xcent") })
                task.checkCommandLineNoMatch([.anySequence, .equal("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName.app.xcent"), .anySequence])

                task.checkInputs(contain: [NodePattern.path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/__preview.dylib")])
                task.checkOutputs([
                    .path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/__preview.dylib"),
                    .name("CodeSign /tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/__preview.dylib"),
                ])
            }

            results.checkTask(.matchRule(["CodeSign", "/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib"])) { task in
                #expect(!task.inputs.contains { $0.path == Path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName.app.xcent") })
                task.checkCommandLineNoMatch([.anySequence, .equal("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName.app.xcent"), .anySequence])

                task.checkInputs(contain: [NodePattern.path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib")])
                task.checkOutputs([
                    .path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib"),
                    .name("CodeSign /tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib"),
                ])
            }

            results.checkTask(.matchRule(["GenerateDSYMFile", "/tmp/Test/ProjectName/build/Debug/TargetName.app.dSYM", "/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib"])) { _ in }

            // The shim executable

            for arch in archs {
                results.checkTask([.matchRule(["ConstructStubExecutorLinkFileList", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName-ExecutorLinkFileList-normal-\(arch).txt"])]) { task in
                    task.checkCommandLineMatches(
                        [
                            .equal("construct-stub-executor-link-file-list"),
                            .equal("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName.debug.dylib"),
                            .suffix("libPreviewsJITStubExecutor_no_swift_entry_point.a"),
                            .suffix("libPreviewsJITStubExecutor.a"),
                            .equal("--output"),
                            .equal("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName-ExecutorLinkFileList-normal-\(arch).txt"),
                        ]
                    )
                }

                results.checkTask(.matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName", "normal", arch])) { task in
                    task.checkCommandLineContainsUninterrupted([
                        "-o",
                        "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName",
                    ])

                    // The shim should receive linker flags pointing to the previews dylib.
                    task.checkCommandLineContainsUninterrupted([
                        "-e",
                        "___debug_blank_executor_main",
                        "-Xlinker",
                        "-sectcreate",
                        "-Xlinker",
                        "__TEXT",
                        "-Xlinker",
                        "__debug_dylib",
                    ])

                    task.checkCommandLineContainsUninterrupted([
                        "-sectcreate",
                        "-Xlinker",
                        "__TEXT",
                        "-Xlinker",
                        "__debug_instlnm",
                    ])

                    // The shim should link against the dylib
                    task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName.debug.dylib")])

                    // The shim should not link .o files (the dylib should have linked the .o files)
                    #expect(!task.inputs.contains { $0.path == Path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/File.o") })

                    // Should use the executor link file list
                    task.checkCommandLineMatches(
                        [
                            .anySequence,
                            .equal("-Xlinker"),
                            .equal("-filelist"),
                            .equal("-Xlinker"),
                            .suffix("ExecutorLinkFileList-normal-\(arch).txt"),
                            .anySequence
                        ]
                    )

                    // The shim should have an rpath to @executable_path, so that it can find the preview lib
                    task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])

                    // The shim should not get LD_LTO_OBJECT_FILE
                    task.checkCommandLineNoMatch([.anySequence, .equal("-object_path_lto"), .anySequence])
                }
            }

            results.checkTask(.matchRule(["CreateUniversalBinary", "/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName", "normal", archsJoined])) { task in
                for arch in archs {
                    task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName")])
                }
            }

            results.checkTask(.matchRule(["GenerateDSYMFile", "/tmp/Test/ProjectName/build/Debug/TargetName.app.dSYM", "/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName"])) { task in
                task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName")])
            }

            results.checkTask(.matchRule(["CopySwiftLibs", "/tmp/Test/ProjectName/build/Debug/TargetName.app"])) { task in
                task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib")])
                task.checkCommandLineContainsUninterrupted(["--scan-executable", "/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib"])
            }

            results.checkTask(.matchRule(["CodeSign", "/tmp/Test/ProjectName/build/Debug/TargetName.app"])) { task in
                for node in task.inputs + task.outputs {
                    #expect(node.path != Path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib"))
                }

                task.checkCommandLineContains(["/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName.app.xcent"])
                task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/TargetName.app.xcent")])
                task.checkOutputs([
                    .path("/tmp/Test/ProjectName/build/Debug/TargetName.app"),
                    .path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName"),
                    .path("/tmp/Test/ProjectName/build/Debug/TargetName.app/_CodeSignature"),
                    .name("CodeSign /tmp/Test/ProjectName/build/Debug/TargetName.app"),
                ])
            }
        }
    }

    /// Ensure that we're handling simulator entitlements correctly, because they're passed through ld instead of codesign, and we're splitting the traditional single ld into two
    @Test(.requireSDKs(.iOS))
    func previewsDylibModeSimulatorEntitlements() async throws {
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("File.swift"),
                    TestFile("Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "ENABLE_PREVIEWS": "NO",
                            "ENABLE_XOJIT_PREVIEWS": "YES",
                            "ENABLE_DEBUG_DYLIB": "YES",
                            "INFOPLIST_FILE": "Sources/Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File.swift"),
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        let fs = PseudoFS()
        try fs.writeSimulatedPreviewsJITStubExecutorLibraries(sdk: core.loadSDK(.iOSSimulator))

        await tester.checkBuild(runDestination: .iOSSimulator, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/ProjectName/build/Debug-iphonesimulator/TargetName.app/TargetName.debug.dylib")) { task in
                task.checkCommandLineNoMatch([
                    .equal("/tmp/Test/ProjectName/build/ProjectName.build/Debug-iphonesimulator/TargetName.build/TargetName.app-Simulated.xcent"),
                ])
            }

            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/ProjectName/build/Debug-iphonesimulator/TargetName.app/TargetName")) { task in
                task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/Debug-iphonesimulator/TargetName.app/TargetName.debug.dylib")])

                task.checkInputs(contain: [.path("/tmp/Test/ProjectName/build/ProjectName.build/Debug-iphonesimulator/TargetName.build/TargetName.app-Simulated.xcent")])
                task.checkCommandLineContains(["/tmp/Test/ProjectName/build/ProjectName.build/Debug-iphonesimulator/TargetName.build/TargetName.app-Simulated.xcent"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func unitTestHostGetsPreviewsDylibLinkedAsLibraryWhenPresent() async throws {
        let core = try await getCore()
        let archs = ["x86_64", "x86_64h"]
        let archsJoined = archs.joined(separator: " ")

        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("Info.plist"),
                    TestFile("Entitlements.plist"),
                    TestFile("TestOne.swift"),
                    TestFile("UnitTestTarget-Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "ARCHS": archsJoined,
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "INFOPLIST_FILE": "Sources/UnitTestTarget-Info.plist",
                                "DEFINES_MODULE": "NO",
                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/TargetName.app/Contents/MacOS/TargetName",
                                "BUNDLE_LOADER": "$(TEST_HOST)",
                                "CODE_SIGN_ENTITLEMENTS": "Sources/Entitlements.plist",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ])
                    ],
                    dependencies: ["TargetName"]
                ),
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "ARCHS": archsJoined,
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "ENABLE_DEBUG_DYLIB": "YES",

                                // Added this while the macOS platform is disabled to force building it with the dylib.
                                // Remove with: rdar://122644133 (Re-enable macOS preview dylib mode)
                                "ENABLE_DEBUG_DYLIB_OVERRIDE": "YES",

                                "DEFINES_MODULE": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "CODE_SIGN_ENTITLEMENTS": "Sources/Entitlements.plist",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                        ]),
                    ]
                ),
            ]
        )
        let tester = try TaskConstructionTester(core, testProject)

        // The localFS is used because we need a value for the swiftlang version in order for
        // -disable-previous-implementation-calls-in-dynamic-replacements to be inserted.
        await tester.checkBuild(runDestination: .anyMac, fs: localFS) { results in
            results.checkNoDiagnostics()

            for arch in archs {
                results.checkTask(
                    .matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/UnitTestTarget.build/Objects-normal/\(arch)/Binary/UnitTestTarget", "normal", arch])
                ) { task in
                    // Make sure the dylib is a dependency.
                    task.checkInputs(contain: [
                        .path("/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib")
                    ])

                    // Make sure the library ends up on the command line.
                    task.checkCommandLineContains(
                        ["/tmp/Test/ProjectName/build/Debug/TargetName.app/Contents/MacOS/TargetName.debug.dylib"]
                    )
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func unitTestHostWithoutBundleLoaderDoesNotGetPreviewsDylibLinkedAsLibrary() async throws {
        let core = try await getCore()
        let archs = ["x86_64", "x86_64h"]
        let archsJoined = archs.joined(separator: " ")

        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("Info.plist"),
                    TestFile("Entitlements.plist"),
                    TestFile("TestOne.swift"),
                    TestFile("UnitTestTarget-Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "ARCHS": archsJoined,
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "INFOPLIST_FILE": "Sources/UnitTestTarget-Info.plist",
                                "DEFINES_MODULE": "NO",
                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/TargetName.app/Contents/MacOS/TargetName",
                                "BUNDLE_LOADER": "",
                                "CODE_SIGN_ENTITLEMENTS": "Sources/Entitlements.plist",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ])
                    ],
                    dependencies: ["TargetName"]
                ),
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "ARCHS": archsJoined,
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "ENABLE_DEBUG_DYLIB": "YES",

                                // Added this while the macOS platform is disabled to force building it with the dylib.
                                // Remove with: rdar://122644133 (Re-enable macOS preview dylib mode)
                                "ENABLE_DEBUG_DYLIB_OVERRIDE": "YES",

                                "DEFINES_MODULE": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "CODE_SIGN_ENTITLEMENTS": "Sources/Entitlements.plist",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                        ]),
                    ]
                ),
            ]
        )
        let tester = try TaskConstructionTester(core, testProject)

        // The localFS is used because we need a value for the swiftlang version in order for
        // -disable-previous-implementation-calls-in-dynamic-replacements to be inserted.
        await tester.checkBuild(runDestination: .anyMac, fs: localFS) { results in
            results.checkNoDiagnostics()

            for arch in archs {
                results.checkTask(
                    .matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/UnitTestTarget.build/Objects-normal/\(arch)/Binary/UnitTestTarget", "normal", arch])
                ) { task in
                    // Make sure the dylib is not a dependency.
                    task.checkNoInputs(contain: [.pathPattern(.suffix("TargetName.debug.dylib"))])

                    task.checkCommandLineDoesNotContain("TargetName.debug.dylib")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func ldClientNameBuildSettingWithNoDebugDylib() async throws {
        let core = try await getCore()
        let archs = ["x86_64", "x86_64h"]
        let archsJoined = archs.joined(separator: " ")

        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("Info.plist"),
                    TestFile("Entitlements.plist"),
                    TestFile("ClientName-Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "ARCHS": archsJoined,
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "ENABLE_DEBUG_DYLIB": "NO",
                                "LD_CLIENT_NAME": "SpecialName",

                                // Added this while the macOS platform is disabled to force building it with the dylib.
                                // Remove with: rdar://122644133 (Re-enable macOS preview dylib mode)
                                "ENABLE_DEBUG_DYLIB_OVERRIDE": "NO",

                                "DEFINES_MODULE": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "CODE_SIGN_ENTITLEMENTS": "Sources/Entitlements.plist",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                        ]),
                    ]
                ),
            ]
        )
        let tester = try TaskConstructionTester(core, testProject)

        // The localFS is used because we need a value for the swiftlang version in order for
        // -disable-previous-implementation-calls-in-dynamic-replacements to be inserted.
        await tester.checkBuild(runDestination: .anyMac, fs: localFS) { results in
            results.checkNoDiagnostics()

            for arch in archs {
                results.checkTask(
                    .matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName", "normal", arch])
                ) { task in
                    task.checkCommandLineContains(
                        ["-client_name", "SpecialName"]
                    )
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func xOJITLdClientNamePropagatedAsInstallNameToPreviewsDylib() async throws {
        let core = try await getCore()
        let archs = ["x86_64", "x86_64h"]
        let archsJoined = archs.joined(separator: " ")

        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("Info.plist"),
                    TestFile("Entitlements.plist"),
                    TestFile("ClientName-Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "ARCHS": archsJoined,
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "ENABLE_DEBUG_DYLIB": "YES",
                                "LD_CLIENT_NAME": "SpecialName",

                                // Added this while the macOS platform is disabled to force building it with the dylib.
                                // Remove with: rdar://122644133 (Re-enable macOS preview dylib mode)
                                "ENABLE_DEBUG_DYLIB_OVERRIDE": "YES",

                                "DEFINES_MODULE": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "CODE_SIGN_ENTITLEMENTS": "Sources/Entitlements.plist",
                                "CODE_SIGN_IDENTITY": "-",
                            ]
                        ),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                        ]),
                    ]
                ),
            ]
        )
        let tester = try TaskConstructionTester(core, testProject)

        // The localFS is used because we need a value for the swiftlang version in order for
        // -disable-previous-implementation-calls-in-dynamic-replacements to be inserted.
        await tester.checkBuild(runDestination: .anyMac, fs: localFS) { results in
            results.checkNoDiagnostics()

            for arch in archs {
                // The debug dylib should have the original target name
                results.checkTask(
                    .matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName.debug.dylib", "normal", arch])
                ) { task in
                    // Debug dylib should get the client name as its install name.
                    task.checkCommandLineContains(
                        ["-install_name", "@rpath/SpecialName.debug.dylib"]
                    )

                    // Debug dylib should get a linker redirect indicating the path to the dylib is the
                    // original name, not the client name.
                    task.checkCommandLineContains([
                        // First, assert that the entry point alias exists. We'll use this symbol as our
                        // "known symbol" to create another alias to the `$ld$previous` symbol.
                        "-Xlinker", "-alias",
                        "-Xlinker", "_main",
                        "-Xlinker", "___debug_main_executable_dylib_entry_point",

                        // Using `-alias` with a known symbol as a way of injecting the $ld$previous symbol
                        // from the command line.
                        "-Xlinker", "-alias",
                        "-Xlinker", "___debug_main_executable_dylib_entry_point",
                        "-Xlinker", "$ld$previous$@rpath/TargetName.debug.dylib$$1$1.0$9999.0$$",
                    ])

                    // And not have a client name specified.
                    task.checkCommandLineDoesNotContain("-client_name")
                }

                results.checkTask(
                    .matchRule(["Ld", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/\(arch)/Binary/TargetName", "normal", arch])
                ) { task in
                    // Main binary should not get the client name (it does not contain the users code)
                    task.checkCommandLineDoesNotContain("-client_name")

                    // It should link against the debug dylib with the target name, even though the install name is different.
                    task.checkCommandLineMatches([.suffix("TargetName.debug.dylib")])
                }
            }
        }
    }

    /// Test the basics of XOJIT task construction, primarily the input/output dependencies of the asset catalog tasks.
    @Test(.requireSDKs(.iOS))
    func XOJITBasics() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                        TestFile("Assets.xcassets"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ASSETCATALOG_EXEC": actoolPath.str,
                        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.test.ProjectName",
                        "SDKROOT": "iphoneos",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                            ]),
                            TestResourcesBuildPhase([
                                TestBuildFile("Assets.xcassets"),
                            ])
                        ]
                    ),
                ]
            )

            let core = try await self.getCore()
            let tester = try TaskConstructionTester(core, testProject)

            // Concrete iOS simulator destination with overrides for an iPhone 14 Pro
            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                "ASSETCATALOG_FILTER_FOR_DEVICE_MODEL": "iPhone15,2",
                "ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION": core.loadSDK(.iOSSimulator).defaultDeploymentTarget,
                "ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION": "iPhone15,2",
                "BUILD_ACTIVE_RESOURCES_ONLY": "YES",
                "TARGET_DEVICE_IDENTIFIER": "DB9FA063-8DA7-41C1-835E-EC616E6AF448",
                "TARGET_DEVICE_MODEL": "iPhone15,2",
                "TARGET_DEVICE_OS_VERSION": core.loadSDK(.iOSSimulator).defaultDeploymentTarget,
                "TARGET_DEVICE_PLATFORM_NAME": "iphonesimulator",

                // And XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",

                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_IDENTITY": "-",
            ])

            final class ClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
                override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                    if commandLine.first.map(Path.init)?.basename == "actool", commandLine.dropFirst().first != "--version" {
                        return .result(status: .exit(0), stdout: Data("{}".utf8), stderr: Data())
                    }
                    return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                }
            }

            let fs = PseudoFS()
            try fs.writeSimulatedPreviewsJITStubExecutorLibraries(sdk: core.loadSDK(.iOSSimulator))

            let actoolPath = try await self.actoolPath

            await tester.checkBuild(buildParameters, runDestination: .iOSSimulator, fs: fs, clientDelegate: ClientDelegate()) { results in
                results.checkNoDiagnostics()
                results.checkNoNotes()

                results.checkTasks(.matchRuleItemPattern(.prefix("Swift"))) { _ in }
                results.consumeTasksMatchingRuleTypes(["Copy", "CopySwiftLibs", "ExtractAppIntentsMetadata", "Gate", "GenerateDSYMFile", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "ClangStatCache", "RegisterExecutionPolicyException", "AppIntentsSSUTraining", "ProcessInfoPlistFile", "Touch", "Validate", "LinkAssetCatalogSignature", "CodeSign", "ProcessProductPackaging", "ProcessProductPackagingDER", "Ld"])

                results.checkTask(.matchRuleType("GenerateAssetSymbols")) { task in
                    task.checkInputs([
                        .path("\(srcRoot.str)/Sources/Assets.xcassets"),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--begin-compiling"))),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])
                    task.checkOutputs([
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/GeneratedAssetSymbols.swift"),
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/GeneratedAssetSymbols.h"),
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/GeneratedAssetSymbols-Index.plist")
                    ])
                    task.checkRuleInfo(["GenerateAssetSymbols", "\(srcRoot.str)/Sources/Assets.xcassets"])
                    task.checkCommandLine([actoolPath.str, "\(srcRoot.str)/Sources/Assets.xcassets", "--compile", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies", "--output-partial-info-plist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist", "--app-icon", "AppIcon", "--compress-pngs", "--enable-on-demand-resources", "YES", "--development-region", "English", "--target-device", "iphone", "--minimum-deployment-target", core.loadSDK(.iOSSimulator).defaultDeploymentTarget, "--platform", "iphonesimulator", "--bundle-identifier", "com.test.ProjectName", "--generate-swift-asset-symbol-extensions", "NO", "--generate-swift-asset-symbols", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/GeneratedAssetSymbols.swift", "--generate-objc-asset-symbols", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/GeneratedAssetSymbols.h", "--generate-asset-symbol-index", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/GeneratedAssetSymbols-Index.plist"])
                }

                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { task in
                    task.checkInputs([
                        .path("\(srcRoot.str)/Sources/Assets.xcassets"),
                        .name("MkDir \(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned"), // path node
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned"), // path node
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--begin-compiling"))),
                        .name("WorkspaceHeaderMapVFSFilesWritten"),
                    ])
                    task.checkOutputs([
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned"), // directory tree node,
                        .any,
                        .any
                    ])
                    task.checkRuleInfo(["CompileAssetCatalogVariant", "thinned", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app", "\(srcRoot.str)/Sources/Assets.xcassets"])
                    task.checkCommandLine([actoolPath.str, "\(srcRoot.str)/Sources/Assets.xcassets", "--compile", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_thinned", "--output-partial-info-plist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_thinned", "--app-icon", "AppIcon", "--compress-pngs", "--enable-on-demand-resources", "YES", "--filter-for-thinning-device-configuration", "iPhone15,2", "--filter-for-device-os-version", core.loadSDK(.iOSSimulator).defaultDeploymentTarget, "--development-region", "English", "--target-device", "iphone", "--minimum-deployment-target", core.loadSDK(.iOSSimulator).defaultDeploymentTarget, "--platform", "iphonesimulator"])
                }

                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("unthinned")) { task in
                    task.checkInputs([
                        .path("\(srcRoot.str)/Sources/Assets.xcassets"),
                        .name("MkDir \(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned"),
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned"), // path node
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--begin-compiling"))),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])
                    task.checkOutputs([
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned"), // directory tree node
                        .any,
                        .any
                    ])
                    task.checkRuleInfo(["CompileAssetCatalogVariant", "unthinned", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app", "\(srcRoot.str)/Sources/Assets.xcassets"])
                    task.checkCommandLine([actoolPath.str, "\(srcRoot.str)/Sources/Assets.xcassets", "--compile", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_unthinned", "--output-partial-info-plist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_unthinned", "--app-icon", "AppIcon", "--compress-pngs", "--enable-on-demand-resources", "YES", "--development-region", "English", "--target-device", "iphone", "--minimum-deployment-target", core.loadSDK(.iOSSimulator).defaultDeploymentTarget, "--platform", "iphonesimulator"])
                }

                results.checkTask(.matchRuleType("LinkAssetCatalog")) { task in
                    task.checkInputs([
                        .path("\(srcRoot.str)/Sources/Assets.xcassets"),
                        .name("MkDir \(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app"),
                        .path("\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app"),
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned"), // directory tree node
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned"), // directory tree node
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_signature"),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--begin-compiling"))),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])
                    task.checkOutputs([
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist"),
                        .path("\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/Assets.car"),
                    ])
                    task.checkRuleInfo(["LinkAssetCatalog", "\(srcRoot.str)/Sources/Assets.xcassets"])
                    task.checkCommandLine(["builtin-linkAssetCatalog", "--thinned", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned", "--thinned-dependencies", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_thinned", "--thinned-info-plist-content", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_thinned", "--unthinned", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned", "--unthinned-dependencies", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_unthinned", "--unthinned-info-plist-content", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_unthinned", "--output", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app", "--plist-output", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist"])
                }

                results.checkTask(.matchRuleType("ConstructStubExecutorLinkFileList")) { task in
                    task.checkInputs([
                        .pathPattern(.suffix("/libPreviewsJITStubExecutor_no_swift_entry_point.a")),
                        .pathPattern(.suffix("/libPreviewsJITStubExecutor.a")),
                        .path("\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget.debug.dylib"),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-AppTarget-T-AppTarget-"), .suffix("--begin-linking"))),
                    ])
                    task.checkOutputs([
                        .path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-ExecutorLinkFileList-normal-x86_64.txt"),
                    ])
                    task.checkRuleInfo([
                        "ConstructStubExecutorLinkFileList", .suffix("AppTarget-ExecutorLinkFileList-normal-x86_64.txt")
                    ])
                    task.checkCommandLineMatches(
                        [
                            .equal("construct-stub-executor-link-file-list"),
                            .equal("\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget.debug.dylib"),
                            .suffix("/Developer/usr/lib/libPreviewsJITStubExecutor_no_swift_entry_point.a"),
                            .suffix("/Developer/usr/lib/libPreviewsJITStubExecutor.a"),
                            .equal("--output"),
                            .equal("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-ExecutorLinkFileList-normal-x86_64.txt"),
                        ]
                    )
                }

                results.checkNoTask()
            }
        }
    }

    /// Test that the `__info_plist` section ends up in the stub executor instead of the preview dylib when `CREATE_INFOPLIST_SECTION_IN_BINARY` is enabled.
    @Test(.requireSDKs(.iOS))
    func xOJITEmbeddedInfoPlist() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.test.ProjectName",
                        "SDKROOT": "iphoneos",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                            ]),
                        ]
                    ),
                ]
            )

            let core = try await self.getCore()
            let tester = try TaskConstructionTester(core, testProject)

            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                // XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",
                "ENABLE_DEBUG_DYLIB": "YES",

                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_IDENTITY": "-",
            ])

            final class ClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
                override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                    if commandLine.first.map(Path.init)?.basename == "actool", commandLine.dropFirst().first != "--version" {
                        return .result(status: .exit(0), stdout: Data("{}".utf8), stderr: Data())
                    }
                    return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                }
            }

            let fs = PseudoFS()
            try fs.writeSimulatedPreviewsJITStubExecutorLibraries(sdk: core.loadSDK(.iOSSimulator))

            await tester.checkBuild(buildParameters, runDestination: .iOSSimulator, fs: fs, clientDelegate: ClientDelegate()) { results in
                results.checkNoDiagnostics()
                results.checkNoNotes()

                results.checkTasks(.matchRuleItemPattern(.prefix("Swift"))) { _ in }
                results.consumeTasksMatchingRuleTypes(["Copy", "CopySwiftLibs", "ExtractAppIntentsMetadata", "Gate", "GenerateDSYMFile", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "ClangStatCache", "RegisterExecutionPolicyException", "AppIntentsSSUTraining", "ProcessInfoPlistFile", "Touch", "Validate", "LinkAssetCatalogSignature", "CodeSign", "ProcessProductPackaging", "ProcessProductPackagingDER", "ConstructStubExecutorLinkFileList"])

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/Tool", "normal"])) { task in
                    task.checkCommandLineContainsUninterrupted(["-sectcreate", "__TEXT", "__info_plist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/Tool.build/Objects-normal/x86_64/Processed-Info.plist"])
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/Tool.debug.dylib", "normal"])) { task in
                    task.checkCommandLineDoesNotContain("__info_plist")
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/__preview.dylib", "normal"])) { task in
                    task.checkCommandLineDoesNotContain("__info_plist")
                }

                results.checkNoTask()
            }
        }
    }

    /// Test that any `-dyld_env` arguments end up in the stub executor instead of the preview dylib when is enabled.
    @Test(.requireSDKs(.iOS))
    func xOJITDyldEnv() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "LD_ENVIRONMENT": "DYLD_X_PATH=/foo",
                        "OTHER_LDFLAGS": "-Wl,-dyld_env,NOT=allowed_here -Xlinker -dyld_env -Xlinker NOR=this",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.test.ProjectName",
                        "SDKROOT": "iphoneos",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                            ]),
                        ]
                    ),
                ]
            )

            let core = try await self.getCore()
            let tester = try TaskConstructionTester(core, testProject)

            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                // XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",
                "ENABLE_DEBUG_DYLIB": "YES",

                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_IDENTITY": "-",
            ])

            final class ClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
                override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                    if commandLine.first.map(Path.init)?.basename == "actool", commandLine.dropFirst().first != "--version" {
                        return .result(status: .exit(0), stdout: Data("{}".utf8), stderr: Data())
                    }
                    return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                }
            }

            let fs = PseudoFS()
            try fs.writeSimulatedPreviewsJITStubExecutorLibraries(sdk: core.loadSDK(.iOSSimulator))

            await tester.checkBuild(buildParameters, runDestination: .iOSSimulator, fs: fs, clientDelegate: ClientDelegate()) { results in
                results.checkTasks(.matchRuleItemPattern(.prefix("Swift"))) { _ in }
                results.consumeTasksMatchingRuleTypes(["Copy", "CopySwiftLibs", "ExtractAppIntentsMetadata", "Gate", "GenerateDSYMFile", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "ClangStatCache", "RegisterExecutionPolicyException", "AppIntentsSSUTraining", "ProcessInfoPlistFile", "Touch", "Validate", "LinkAssetCatalogSignature", "CodeSign", "ProcessProductPackaging", "ProcessProductPackagingDER", "ConstructStubExecutorLinkFileList"])

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/__preview.dylib", "normal"])) { task in
                    task.checkCommandLineDoesNotContain("-dyld_env")
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/Tool", "normal"])) { task in
                    // from LD_ENVIRONMENT, which is conditional on MACH_O_TYPE=mh_execute, so the stub executor gets it
                    task.checkCommandLineContainsUninterrupted(["-Xlinker", "-dyld_env", "-Xlinker", "DYLD_X_PATH=/foo"])

                    // from OTHER_LDFLAGS, which is overridden to a custom set of flags _without_ $(inherited), so the stub executor doesn't get them
                    task.checkCommandLineDoesNotContain("-Wl,-dyld_env,NOT=allowed_here")
                    task.checkCommandLineDoesNotContain("NOR=this")
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/Tool.debug.dylib", "normal"])) { task in
                    // from LD_ENVIRONMENT, which is conditional on MACH_O_TYPE=mh_execute, so the previews dylib (which overrides MACH_O_TYPE=mh_dylib) doesn't get it
                    task.checkCommandLineDoesNotContain("-dyld_env")
                    task.checkCommandLineDoesNotContain("DYLD_X_PATH=/foo")

                    // from OTHER_LDFLAGS, which is passed through unchanged to the previews dylib
                    task.checkCommandLineDoesNotContain("-Wl,-dyld_env,NOT=allowed_here")
                    task.checkCommandLineDoesNotContain("NOR=this")
                }

                results.checkWarning(.equal("The OTHER_LDFLAGS build setting is not allowed to contain -dyld_env, use the dedicated LD_ENVIRONMENT build setting instead. (in target 'Tool' from project 'ProjectName')"))
                results.checkWarning(.equal("The OTHER_LDFLAGS build setting is not allowed to contain -dyld_env, use the dedicated LD_ENVIRONMENT build setting instead. (in target 'Tool' from project 'ProjectName')"))

                results.checkNoTask()
                results.checkNoDiagnostics()
                results.checkNoNotes()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func xOJITPropagatingRpaths() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.test.ProjectName",
                        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @loader_path/Frameworks/Foo @loader_path/Frameworks/Foo @loader_path/Frameworks/Foo",
                        "SDKROOT": "iphoneos",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                            ]),
                        ]
                    ),
                ]
            )

            let core = try await self.getCore()
            let tester = try TaskConstructionTester(core, testProject)

            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                // XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",
                "ENABLE_DEBUG_DYLIB": "YES",

                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_IDENTITY": "-",
            ])

            final class ClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
                override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                    if commandLine.first.map(Path.init)?.basename == "actool", commandLine.dropFirst().first != "--version" {
                        return .result(status: .exit(0), stdout: Data("{}".utf8), stderr: Data())
                    }
                    return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                }
            }

            let fs = PseudoFS()
            try fs.writeSimulatedPreviewsJITStubExecutorLibraries(sdk: core.loadSDK(.iOSSimulator))

            await tester.checkBuild(buildParameters, runDestination: .iOSSimulator, fs: fs, clientDelegate: ClientDelegate()) { results in
                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/Tool", "normal"])) { task in
                    task.checkCommandLineContains([
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/Frameworks/Foo",
                    ])
                    // Ensure rpaths are deduplicated
                    #expect(task.commandLine.filter { $0 == "-rpath" }.count == 2)
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/__preview.dylib", "normal"])) { task in
                    task.checkCommandLineDoesNotContain("-rpath")
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/Tool.debug.dylib", "normal"])) { task in
                    task.checkCommandLineContains([
                        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/Frameworks/Foo",
                    ])
                    // Ensure rpaths are deduplicated
                    #expect(task.commandLine.filter { $0 == "-rpath" }.count == 1)
                }
            }
        }
    }

}
