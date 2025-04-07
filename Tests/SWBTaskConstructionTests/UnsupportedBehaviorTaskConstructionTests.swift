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

/// Tests for behavior which is not officially supported and which we would prefer to more explicitly not support, but which we must presently support because someone critical is relying on it.
@Suite
fileprivate struct UnsupportedBehaviorTaskConstructionTests: CoreBasedTests {
    /// Test that targets which override `TARGET_BUILD_DIR` don't fail, specifically in the complicated instance of a unit test target which defines `TEST_HOST`.
    ///
    /// Some projects override `TARGET_BUILD_DIR` - even though that setting is not supposed to be set in the project but only derived by the build system - which causes them to fail the check in `XCTestBundleProductTypeSpec.addTestHostSettings()` that `TEST_HOST` is inside `TARGET_BUILD_DIR`.  c.f. <rdar://problem/43032765>, which contains a sample project which this test imitates.
    @Test(.requireSDKs(.iOS))
    func overridingTargetBuildDirInApplicationUnitTestTarget() async throws {
        let core = try await getCore()
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("ClassOne.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("UnitTestTarget-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ARCHS[sdk=iphoneos*]": "arm64",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": swiftVersion,
                        // Settings to redirect TARGET_BUILD_DIR.
                        "REDIRECT_CONFIG_BUILD_DIR": "$(SRCROOT)/_build",
                        "REDIRECT_OUT_DIR": "$(SRCROOT)/_build",
                        "IOS_CONFIG_BUILD_DIR": "$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
                        "SYMROOT": "$(REDIRECT_CONFIG_BUILD_DIR)/$(PROJECT)",
                        "SYMROOT[sdk=iphonesimulator*]": "$(REDIRECT_CONFIG_BUILD_DIR)/$(PROJECT)/$(IOS_CONFIG_BUILD_DIR)",
                        "SYMROOT[sdk=iphoneos*]": "$(REDIRECT_CONFIG_BUILD_DIR)/$(PROJECT)/$(IOS_CONFIG_BUILD_DIR)",
                        "CONFIGURATION_BUILD_DIR": "$(SYMROOT)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UnitTestTarget-Info.plist",
                                                // We need to use this value - rather than the commented-out value below which is the default value from the target template - in order to get this to work when redirecting TARGET_BUILD_DIR.
                                                "TEST_HOST": "$(REDIRECT_OUT_DIR)/$(PROJECT_NAME)/AppTarget.app/AppTarget",
                                                //                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/AppTarget",
                                                "BUNDLE_LOADER": "$(TEST_HOST)",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                                // Settings to redirect TARGET_BUILD_DIR.
                                                "TARGET_BUILD_DIR": "$(REDIRECT_OUT_DIR)/$(PROJECT_NAME)/AppTarget.app/PlugIns",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ]),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "AppTarget-Info.plist",
                                                // Settings to redirect TARGET_BUILD_DIR.
                                                "TARGET_BUILD_DIR": "$(REDIRECT_OUT_DIR)/$(PROJECT_NAME)",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                    ]
                ),
            ])
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let unitTestFrameworkSubpaths = [
            "Library/Frameworks/XCTest.framework",
            "Library/Frameworks/Testing.framework",
            "Library/Frameworks/XCUIAutomation.framework",
            "Library/PrivateFrameworks/XCTestCore.framework",
            "Library/PrivateFrameworks/XCUnit.framework",
            "Library/PrivateFrameworks/XCUIAutomation.framework",
            "Library/PrivateFrameworks/XCTestSupport.framework",
            "Library/PrivateFrameworks/XCTAutomationSupport.framework",
            "usr/lib/libXCTestBundleInject.dylib",
            "usr/lib/libXCTestSwiftSupport.dylib",
        ]

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        for platform in ["iPhoneOS", "iPhoneSimulator"] {
            for frameworkSubpath in unitTestFrameworkSubpaths {
                let frameworkPath = core.developerPath.path.join("Platforms/\(platform).platform/Developer").join(frameworkSubpath)
                try fs.createDirectory(frameworkPath.dirname, recursive: true)
                try fs.write(frameworkPath, contents: ByteString(encodingAsUTF8: frameworkPath.basename))
            }
        }
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        try await fs.writePlist(Path(SRCROOT).join("Entitlements.plist"), .plDict([:]))

        // Check a debug build for the device.
        await tester.checkBuild(runDestination: .iOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate and build directory related tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            // Check that the app target to make sure it's laying down content in the expected place.
            results.checkTarget("AppTarget") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "\(SRCROOT)/_build/aProject/AppTarget.app/Info.plist", "\(SRCROOT)/AppTarget-Info.plist"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("\(SRCROOT)/_build/aProject/AppTarget.app/AppTarget")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopySwiftLibs", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }

                // Skip the other tasks in this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target to make sure it's laying down content in the expected place.
            results.checkTarget("UnitTestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest/Info.plist", "\(SRCROOT)/UnitTestTarget-Info.plist"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest/UnitTestTarget")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopySwiftLibs", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }

                // Skip the other tasks in this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check a debug build for the simulator.
        await tester.checkBuild(runDestination: .iOSSimulator, fs: fs) { results in
            // For debugging convenience, consume all the Gate and build directory related tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            // Check that results for the app target were generated, but they're not what we're testing here.
            results.checkTarget("AppTarget") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "\(SRCROOT)/_build/aProject/AppTarget.app/Info.plist", "\(SRCROOT)/AppTarget-Info.plist"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("\(SRCROOT)/_build/aProject/AppTarget.app/AppTarget")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopySwiftLibs", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/_build/aProject/AppTarget.app"])) { _ in }

                // Skip the other tasks in this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the first unit test target.  This one does not perform the copying of the test frameworks or re-signing the app target's product.
            results.checkTarget("UnitTestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest/Info.plist", "\(SRCROOT)/UnitTestTarget-Info.plist"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest/UnitTestTarget")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopySwiftLibs", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/_build/aProject/AppTarget.app/PlugIns/UnitTestTarget.xctest"])) { _ in }

                // Skip the other tasks in this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test that a project which excludes all of its sources via `EXCLUDED_SOURCE_FILE_NAMES`, builds successfully.
    /// We should correctly detect that the target has no object-producing sources, and essentially end up doing nothing (including NOT generating tasks which would otherwise depend on the non-existent produced binary).
    @Test(.requireSDKs(.iOS))
    func wildcardExcludedSourceFileNames() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("foo.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SDKROOT": "iphoneos",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "EXCLUDED_SOURCE_FILE_NAMES": "*",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo.c",
                        ]),
                    ]
                ),
            ])
        try await TaskConstructionTester(getCore(), testProject).checkBuild(runDestination: .iOS) { results in
            results.checkNoDiagnostics()
        }
    }

    /// Tests that overriding `PRODUCT_TYPE` has no effect.
    @Test(.requireSDKs(.macOS))
    func overridingProductType() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("foo.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_TYPE": "com.apple.product-type.tool",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .xpcService,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo.c",
                        ]),
                    ]
                ),
            ])
        try await TaskConstructionTester(getCore(), testProject).checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineLastArgumentEqual("/tmp/Test/aProject/build/Debug/AppTarget.xpc/Contents/MacOS/AppTarget")
            }
        }
    }
}
