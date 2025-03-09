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
import SWBTestSupport
import SWBUtil
import SWBProtocol

import SWBTaskConstruction

@Suite
fileprivate struct HostBuildToolTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func basics() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("Foo", children: [
                TestFile("tool.swift"),
                TestFile("frame.swift"),
            ]), buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                        ])], buildPhases: [
                            TestSourcesBuildPhase(["tool.swift"])
                        ]),
                TestStandardTarget("Framework", type: .framework, buildPhases: [
                    TestSourcesBuildPhase(["frame.swift"])
                ], dependencies: [
                    "HostTool"
                ]),
            ]
        )
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)


        await tester.checkBuild(runDestination: .anyMac, targetName: "Framework") { results in
            results.checkNoDiagnostics()
            results.checkTarget("Framework") { frameworkTarget in
                results.checkTarget("HostTool") { hostTarget in

                    // Compilation of the framework target should be blocked until the host tool it depends on is completely finished building.
                    results.checkTask(.matchTarget(frameworkTarget), .matchRuleType("SwiftDriver Compilation"), .matchRuleItem("x86_64")) { compileTask in
                        results.checkTaskFollows(compileTask, .matchTarget(hostTarget), .matchRuleType("Gate"), .matchRuleItemPattern(.and(.prefix("target-HostTool-"), .suffix("-end"))))
                    }
                    results.checkTask(.matchTarget(frameworkTarget), .matchRuleType("SwiftDriver Compilation"), .matchRuleItem("arm64")) { compileTask in
                        results.checkTaskFollows(compileTask, .matchTarget(hostTarget), .matchRuleType("Gate"), .matchRuleItemPattern(.and(.prefix("target-HostTool-"), .suffix("-end"))))
                    }

                    // Host tools should only build for the native architecture.
                    results.checkTaskExists(.matchTarget(hostTarget), .matchRuleType("SwiftDriver Compilation"), .matchRuleItem(Architecture.host.stringValue ?? ""))
                    results.checkNoTask(.matchTarget(hostTarget), .matchRuleType("SwiftDriver Compilation"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func hostToolBuildsForHostPlatform() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("Foo", children: [
                TestFile("dep.swift"),
                TestFile("tool.swift"),
                TestFile("frame.swift"),
            ]), buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                    ]),
            ],
            targets: [
                TestStandardTarget("HostToolDependency", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["dep.swift"])
                ]),
                TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                        ])], buildPhases: [
                            TestSourcesBuildPhase(["tool.swift"])
                        ], dependencies: [
                            "HostToolDependency"
                        ]),
                TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["frame.swift"])
                ], dependencies: [
                    "HostTool"
                ]),
            ]
        )
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let fs = PseudoFS()
        try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")

        await tester.checkBuild(runDestination: .anyMac, targetName: "Framework", fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Framework") { frameworkTarget in
                results.checkTasks(.matchTarget(frameworkTarget), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                    for compileTask in compileTasks {
                        compileTask.checkCommandLineMatches(["-target", .contains("macos")])
                    }
                }
            }
            results.checkTarget("HostTool") { hostTarget in
                results.checkTask(.matchTarget(hostTarget), .matchRuleType("SwiftDriver Compilation")) { compileTask in
                    compileTask.checkCommandLineMatches(["-target", .contains("macos")])
                }
            }

            results.checkTarget("HostToolDependency") { dependencyTarget in
                // FIXME: Ideally, we'd only build this for the native arch.
                results.checkTasks(.matchTarget(dependencyTarget), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                    for compileTask in compileTasks {
                        compileTask.checkCommandLineMatches(["-target", .contains("macos")])
                    }
                }
            }
        }

        await tester.checkBuild(runDestination: .anyiOSDevice, targetName: "Framework", fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Framework") { frameworkTarget in
                results.checkTasks(.matchTarget(frameworkTarget), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                    for compileTask in compileTasks {
                        compileTask.checkCommandLineMatches(["-target", .contains("ios")])
                    }
                }
            }

            // Even when building for an iOS destination, the host tool should still build for macOS.
            results.checkTarget("HostTool") { hostTarget in
                results.checkTask(.matchTarget(hostTarget), .matchRuleType("SwiftDriver Compilation")) { compileTask in
                    compileTask.checkCommandLineMatches(["-target", .contains("macos")])
                }
            }

            results.checkTarget("HostToolDependency") { dependencyTarget in
                // FIXME: Ideally, we'd only build this for the native arch.
                results.checkTasks(.matchTarget(dependencyTarget), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                    for compileTask in compileTasks {
                        compileTask.checkCommandLineMatches(["-target", .contains("macos")])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftMacroPluginLoadingFlags() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("Foo", children: [
                TestFile("dep.swift"),
                TestFile("tool.swift"),
                TestFile("frame.swift"),
                TestFile("frame2.swift"),
                TestFile("app.swift"),
            ]), buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                    ]),
            ],
            targets: [
                TestStandardTarget("HostToolDependency", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["dep.swift"])
                ]),
                TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES": "Framework",
                        ])], buildPhases: [
                            TestSourcesBuildPhase(["tool.swift"])
                        ], dependencies: [
                            "HostToolDependency"
                        ]),
                TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["frame.swift"])
                ], dependencies: [
                    "HostTool"
                ]),
                TestStandardTarget("Framework2", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["frame2.swift"])
                ]),
                TestStandardTarget("App", type: .application, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["app.swift"])
                ], dependencies: [
                    "Framework", "Framework2"
                ]),
            ]
        )
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let fs = PseudoFS()
        try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")

        let destinations: [RunDestinationInfo] = [.anyMac, .anyiOSDevice]
        for destination in destinations {
            await tester.checkBuild(runDestination: destination, targetName: "App", fs: fs) { results in
                results.checkNoDiagnostics()

                // Framework and App compilation should both depend on and pass flags to load the macro plugin
                for targetName in ["Framework", "App"] {
                    results.checkTarget(targetName) { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                            for compileTask in compileTasks {
                                compileTask.checkCommandLineMatches(["-Xfrontend", "-load-plugin-executable", "-Xfrontend", "/tmp/aWorkspace/aProject/build/Debug/HostTool#Framework"])
                                compileTask.checkInputs(contain: [.path("/tmp/aWorkspace/aProject/build/Debug/HostTool")])
                            }
                        }
                    }
                }

                // Other targets should not pass the flag/have the input.
                for targetName in ["HostTool", "HostToolDependency", "Framework2"] {
                    results.checkTarget(targetName) { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                            for compileTask in compileTasks {
                                compileTask.checkCommandLineNoMatch(["-Xfrontend", "-load-plugin-executable", "-Xfrontend", "/tmp/aWorkspace/aProject/build/Debug/HostTool#Framework"])
                                compileTask.checkNoInputs(contain: [.path("/tmp/aWorkspace/aProject/build/Debug/HostTool")])
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftMacroBinaryPluginLoadingFlags() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("Foo", children: [
                TestFile("frame.swift"),
                TestFile("frame2.swift"),
                TestFile("app.swift"),
            ]), buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                    ]),
            ],
            targets: [
                TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            "SWIFT_LOAD_BINARY_MACROS": "/path/to/macroa#MacroA /path/to/macrob#MacroB1,MacroB2"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["frame.swift"])
                ]),
                TestStandardTarget("Framework2", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["frame2.swift"])
                ]),
                TestStandardTarget("App", type: .application, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator"
                        ]),
                ], buildPhases: [
                    TestSourcesBuildPhase(["app.swift"])
                ], dependencies: [
                    "Framework", "Framework2"
                ]),
            ]
        )
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let fs = PseudoFS()
        try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")

        try fs.createDirectory(Path("/path/to"), recursive: true)
        try fs.write(Path("/path/to/macroa"), contents: "")
        try fs.write(Path("/path/to/macrob"), contents: "")

        let destinations: [RunDestinationInfo] = [.anyMac, .anyiOSDevice]
        for destination in destinations {
            await tester.checkBuild(runDestination: destination, targetName: "App", fs: fs) { results in
                results.checkNoDiagnostics()

                // Framework and App compilation should both depend on and pass flags to load the macro plugin
                for targetName in ["Framework", "App"] {
                    results.checkTarget(targetName) { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                            for compileTask in compileTasks {
                                compileTask.checkCommandLineMatches(["-Xfrontend", "-load-plugin-executable", "-Xfrontend", "/path/to/macroa#MacroA"])
                                compileTask.checkCommandLineMatches(["-Xfrontend", "-load-plugin-executable", "-Xfrontend", "/path/to/macrob#MacroB1,MacroB2"])
                                compileTask.checkInputs(contain: [.path("/path/to/macroa"), .path("/path/to/macrob")])
                            }
                        }
                    }
                }

                // The other framework should not load the plugin.
                results.checkTarget("Framework2") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { compileTasks in
                        for compileTask in compileTasks {
                            compileTask.checkCommandLineNoMatch(["-Xfrontend", "-load-plugin-executable", "-Xfrontend", "/path/to/macroa#MacroA"])
                            compileTask.checkCommandLineNoMatch(["-Xfrontend", "-load-plugin-executable", "-Xfrontend", "/path/to/macrob#MacroB1,MacroB2"])
                            compileTask.checkNoInputs(contain: [.path("/path/to/macroa"), .path("/path/to/macrob")])
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftMacroSwiftSyntaxSearchPaths() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("Foo", children: [
                TestFile("tool.swift"),
            ]), buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SWIFT_VERSION": swiftVersion,
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str
                    ]),
            ],
            targets: [
                TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "auto",
                            "SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES": "Framework",
                            "SWIFT_ADD_TOOLCHAIN_SWIFTSYNTAX_SEARCH_PATHS": "YES",
                        ])], buildPhases: [
                            TestSourcesBuildPhase(["tool.swift"])
                        ]),
            ]
        )
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let fs = PseudoFS()

        await tester.checkBuild(runDestination: .macOS, targetName: "HostTool", fs: fs) { results in
            results.checkNoDiagnostics()

            // Other targets should not pass the flag/have the input.
            results.checkTarget("HostTool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { compileTask in
                    compileTask.checkCommandLineMatches(["-I", .suffix("/usr/lib/swift/host")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { linkTask in
                    linkTask.checkCommandLineMatches([.and(.suffix("/usr/lib/swift/host"), .prefix("-L"))])
                }
            }
        }
    }
}
