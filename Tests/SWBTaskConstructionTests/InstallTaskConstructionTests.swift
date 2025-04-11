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

/// Test interesting characteristics of install builds.
@Suite
fileprivate struct InstallTaskConstructionTests: CoreBasedTests {
    // FIXME: Once <rdar://problem/45465505> is addressed and the hierarchical layout is the default then this can become a more general test.
    //
    /// Tests that the hierarchical SYMROOT layout works as expected when USE_HIERARCHICAL_LAYOUT_FOR_COPIED_ASIDE_PRODUCTS is enabled.
    @Test(.requireSDKs(.macOS))
    func hierarchicalSYMROOTLayout() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("LibraryOne.m"),
                    TestFile("LibraryTwo.m"),
                    TestFile("LibraryThree.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Release",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "macosx",
                        "BUILD_VARIANTS": "normal profile",
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "Aggregate",
                    buildConfigurations: [TestBuildConfiguration("Release", buildSettings: [:])],
                    dependencies: [
                        "PublicLibrary",
                        "LocalLibrary",
                        "UninstalledLibrary",
                        "UninstalledTool",
                    ]
                ),
                TestStandardTarget(
                    "PublicLibrary",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Release",
                            buildSettings: [
                                "PRODUCT_NAME": "MyLibrary",
                                "INSTALL_PATH": "/usr/lib",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "LibraryOne.m",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "LocalLibrary",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Release",
                            buildSettings: [
                                "PRODUCT_NAME": "MyLibrary",
                                "INSTALL_PATH": "/usr/local/lib",
                                "DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "LibraryTwo.m",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "UninstalledLibrary",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Release",
                            buildSettings: [
                                "PRODUCT_NAME": "MyLibrary",
                                "INSTALL_PATH": "",                 // Will cause SKIP_INSTALL to be enabled.
                                "DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "LibraryThree.m",
                        ]),
                    ]
                ),
                // An uninstalled tool which does not have a name collision with the libraries, to further test uninstalled behaviors.
                TestStandardTarget(
                    "UninstalledTool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Release",
                            buildSettings: [
                                "PRODUCT_NAME": "tool",
                                "INSTALL_PATH": "",                 // Will cause SKIP_INSTALL to be enabled.
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "LibraryThree.m",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the debug build.
        let overrides = [
            "RETAIN_RAW_BINARIES": "YES",
            "SYMROOT": "/tmp/symroot",
            "OBJROOT": "/tmp/objroot",
            "DSTROOT": "/tmp/dstroot",
            "USE_HIERARCHICAL_LAYOUT_FOR_COPIED_ASIDE_PRODUCTS": "YES",
        ]
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: overrides), runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.consumeTasksMatchingRuleTypes(["Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "MkDir", "Strip", "SetOwnerAndGroup", "SetMode", "Touch", "RegisterWithLaunchServices"])

            results.checkTarget("PublicLibrary") { target in
                // There should be a symlink command for each build variant in the BUILT_PRODUCTS_DIR.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/symroot/Release/BuiltProducts/MyLibrary.dylib", "../../../dstroot/usr/lib/MyLibrary.dylib"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "../../../dstroot/usr/lib/MyLibrary.dylib", "/tmp/symroot/Release/BuiltProducts/MyLibrary.dylib"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/symroot/Release/BuiltProducts/MyLibrary_profile.dylib", "../../../dstroot/usr/lib/MyLibrary_profile.dylib"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "../../../dstroot/usr/lib/MyLibrary_profile.dylib", "/tmp/symroot/Release/BuiltProducts/MyLibrary_profile.dylib"])
                }

                // The copied-aside products should be at the INSTALL_PATH inside the SYMROOT.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/usr/lib/MyLibrary.dylib", "/tmp/dstroot/usr/lib/MyLibrary.dylib"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/usr/lib/MyLibrary_profile.dylib", "/tmp/dstroot/usr/lib/MyLibrary_profile.dylib"])) { _ in }
            }

            results.checkTarget("LocalLibrary") { target in
                // There should *not* be symlink commands in the BUILT_PRODUCTS_DIR, because DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS is enabled.
                results.checkNoTask(.matchTarget(target), .matchRuleItem("SymLink"))

                // The copied-aside products should be at the INSTALL_PATH inside the SYMROOT.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/usr/local/lib/MyLibrary.dylib", "/tmp/dstroot/usr/local/lib/MyLibrary.dylib"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/usr/local/lib/MyLibrary_profile.dylib", "/tmp/dstroot/usr/local/lib/MyLibrary_profile.dylib"])) { _ in }
            }

            results.checkTarget("UninstalledLibrary") { target in
                // There should *not* be symlink commands in the BUILT_PRODUCTS_DIR, because DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS is enabled.
                results.checkNoTask(.matchTarget(target), .matchRuleItem("SymLink"))

                // The copied-aside products should be inside UninstalledProducts inside the SYMROOT.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/UninstalledProducts/aProject/UninstalledLibrary/MyLibrary.dylib", "/tmp/objroot/UninstalledProducts/macosx/MyLibrary.dylib"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/UninstalledProducts/aProject/UninstalledLibrary/MyLibrary_profile.dylib", "/tmp/objroot/UninstalledProducts/macosx/MyLibrary_profile.dylib"])) { _ in }
            }

            results.checkTarget("UninstalledTool") { target in
                // There should be a symlink command for each build variant in the BUILT_PRODUCTS_DIR.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/symroot/Release/BuiltProducts/tool", "../../../objroot/UninstalledProducts/macosx/tool"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "../../../objroot/UninstalledProducts/macosx/tool", "/tmp/symroot/Release/BuiltProducts/tool"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/symroot/Release/BuiltProducts/tool_profile", "../../../objroot/UninstalledProducts/macosx/tool_profile"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "../../../objroot/UninstalledProducts/macosx/tool_profile", "/tmp/symroot/Release/BuiltProducts/tool_profile"])
                }

                // The copied-aside products should be inside UninstalledProducts inside the SYMROOT.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/UninstalledProducts/aProject/UninstalledTool/tool", "/tmp/objroot/UninstalledProducts/macosx/tool"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/symroot/UninstalledProducts/aProject/UninstalledTool/tool_profile", "/tmp/objroot/UninstalledProducts/macosx/tool_profile"])) { _ in }
            }
        }
    }

    /// Tests that doing an install to a directory which is a string prefix of the project folder, but not a path prefix of the project folder, works.  Right now this is narrowly testing the fix for <rdar://problem/74366484>.
    @Test(.requireSDKs(.macOS))
    func interestingInstallationDirectories() async throws {
        let projectNameRoot = "XQuartzInstaller"
        let testProject = try await TestProject(
            "\(projectNameRoot)Plugin",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("ClassOne.swift"),
                    TestFile("InstallerSections.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Release",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "macosx",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "\(projectNameRoot)Plugin",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Release",
                            buildSettings: [
                                "INSTALL_PATH": "/",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                        TestCopyFilesBuildPhase([
                            "InstallerSections.plist",
                        ], destinationSubfolder: .absolute, onlyForDeployment: false),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check a build where the DSTROOT is a string-prefix of the SRCROOT.
        var DSTROOT = tester.workspace.projects[0].sourceRoot.dirname.join(projectNameRoot).str
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["DSTROOT": DSTROOT,]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.consumeTasksMatchingRuleTypes(["Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "MkDir", "Strip", "SetOwnerAndGroup", "SetMode", "Touch", "RegisterWithLaunchServices"])

            results.checkTarget("\(projectNameRoot)Plugin") { target in
                // Check that the Copy Files phase task was set up.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(DSTROOT)/InstallerSections.plist", "\(SRCROOT)/InstallerSections.plist"])) { _ in }
            }
        }

        // Check a build where the DSTROOT is *not* a string-prefix of the SRCROOT.
        DSTROOT = tester.workspace.projects[0].sourceRoot.dirname.join("\(projectNameRoot).dst").str
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release", overrides: ["DSTROOT": DSTROOT,]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.consumeTasksMatchingRuleTypes(["Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "MkDir", "Strip", "SetOwnerAndGroup", "SetMode", "Touch", "RegisterWithLaunchServices"])

            results.checkTarget("\(projectNameRoot)Plugin") { target in
                // Check that the Copy Files phase task was set up.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(DSTROOT)/InstallerSections.plist", "\(SRCROOT)/InstallerSections.plist"])) { _ in }
            }
        }
    }
}
