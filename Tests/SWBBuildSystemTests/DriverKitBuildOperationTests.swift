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
import Foundation

@Suite
fileprivate struct DriverKitBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS, .driverKit))
    func multiPlatformAppWithDriver() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "COPY_PHASE_STRIP": "NO",
                                    "DEBUG_INFORMATION_FORMAT": "dwarf",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "PRODUCT_BUNDLE_IDENTIFIER": "com.mycompany.app",
                                        "SUPPORTED_PLATFORMS": "macosx iphoneos",
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "Driver.dext"
                                    ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(SYSTEM_EXTENSIONS_FOLDER_PATH)", onlyForDeployment: false)
                                ],
                                dependencies: ["Driver"]
                            ),
                            TestStandardTarget(
                                "Driver",
                                type: .driverExtension,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "PRODUCT_BUNDLE_IDENTIFIER": "com.mycompany.app.driver",
                                        "SDKROOT": "driverkit",
                                        "SUPPORTED_PLATFORMS": "driverkit",
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]
                            )
                        ])
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            try tester.fs.createDirectory(SRCROOT, recursive: true)
            try tester.fs.write(SRCROOT.join("foo.c"), contents: "int main() { return 0; }")

            try await tester.checkBuild(runDestination: .anyMac) { results in
                results.checkTask(.matchRule(["ValidateEmbeddedBinary", "\(tmpDirPath.str)/Test/aProject/build/Debug/App.app/Contents/Library/SystemExtensions/Driver.dext"])) { task in
                    task.checkCommandLineMatches([.suffix("embeddedBinaryValidationUtility"), "\(tmpDirPath.str)/Test/aProject/build/Debug/App.app/Contents/Library/SystemExtensions/Driver.dext", "-info-plist-path", "\(tmpDirPath.str)/Test/aProject/build/Debug/App.app/Contents/Info.plist"])
                }
            }

            try await tester.checkBuild(runDestination: .anyiOSDevice) { results in
                results.checkTask(.matchRule(["ValidateEmbeddedBinary", "\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/App.app/SystemExtensions/Driver.dext"])) { task in
                    task.checkCommandLineMatches([.suffix("embeddedBinaryValidationUtility"), "\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/App.app/SystemExtensions/Driver.dext", "-info-plist-path", "\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/App.app/Info.plist"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .driverKit))
    func driverKitPlistContent() async throws {
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "DEBUG_INFORMATION_FORMAT": "dwarf",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "INFOPLIST_FILE": "Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Driver",
                                type: .driverExtension,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            let driverkitSDK = core.loadSDK(.driverKit)

            try await tester.fs.writePlist(SRCROOT.join("Info.plist"), .plDict([
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)"),
                "CFBundleName": .plString("$(PRODUCT_NAME)"),
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                contents <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDKROOT": "driverkit"]), runDestination: .macOS, persistent: true) { results in
                let xcodeActualStr = (core.xcodeVersion[0] * 100 + core.xcodeVersion[1] * 10 + core.xcodeVersion[2]).toString(format: "%04d")

                try XCTAssertEqualPropertyListItems(try PropertyList.fromPath(SRCROOT.join("build/Debug-driverkit/Driver.dext/Info.plist"), fs: tester.fs), PropertyListItem.plDict([
                    "BuildMachineOSBuild": .plString("99A98"),
                    "CFBundleDevelopmentRegion": .plString("English"),
                    "CFBundleExecutable": .plString("Driver"),
                    "CFBundleInfoDictionaryVersion": .plString("6.0"),
                    "CFBundleName": .plString("Driver"),
                    "CFBundlePackageType": .plString("DEXT"),
                    "CFBundleSupportedPlatforms": .plArray([.plString("DriverKit")]),
                    "DTCompiler": .plString("com.apple.compilers.llvm.clang.1_0"),
                    "DTPlatformBuild": .plString(#require(core.platformRegistry.lookup(name: "driverkit")?.productBuildVersion)),
                    "DTPlatformName": .plString("driverkit"),
                    // The DTPlatformVersion key is using SDK_MARKETING_FULL_VERSION.
                    "DTPlatformVersion": .plString(driverkitSDK.version),
                    "DTSDKBuild": .plString(""),
                    "DTSDKName": .plString("driverkit\(driverkitSDK.version)"),
                    "DTXcode": .plString(xcodeActualStr),
                    "DTXcodeBuild": .plString(core.xcodeProductBuildVersionString),
                    "OSMinimumDriverKitVersion": .plString(driverkitSDK.defaultDeploymentTarget),
                ]))

                try XCTAssertEqualPropertyListItems(try PropertyList.fromPath(SRCROOT.join("build/Debug-driverkit/Framework.framework/Info.plist"), fs: tester.fs), PropertyListItem.plDict([
                    "BuildMachineOSBuild": .plString("99A98"),
                    "CFBundleDevelopmentRegion": .plString("English"),
                    "CFBundleExecutable": .plString("Framework"),
                    "CFBundleInfoDictionaryVersion": .plString("6.0"),
                    "CFBundleName": .plString("Framework"),
                    "CFBundlePackageType": .plString("FMWK"),
                    "CFBundleSupportedPlatforms": .plArray([.plString("DriverKit")]),
                    "DTCompiler": .plString("com.apple.compilers.llvm.clang.1_0"),
                    "DTPlatformBuild": .plString(#require(core.platformRegistry.lookup(name: "driverkit")?.productBuildVersion)),
                    "DTPlatformName": .plString("driverkit"),
                    // The DTPlatformVersion key is using SDK_MARKETING_FULL_VERSION.
                    "DTPlatformVersion": .plString(driverkitSDK.version),
                    "DTSDKBuild": .plString(""),
                    "DTSDKName": .plString("driverkit\(driverkitSDK.version)"),
                    "DTXcode": .plString(xcodeActualStr),
                    "DTXcodeBuild": .plString(core.xcodeProductBuildVersionString),
                    "OSMinimumDriverKitVersion": .plString(driverkitSDK.defaultDeploymentTarget),
                ]))
            }
        }
    }

    @Test(.requireSDKs(.macOS, .driverKit))
    func driverKitPlistFormat() async throws {
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "DEBUG_INFORMATION_FORMAT": "dwarf",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "INFOPLIST_FILE": "Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Driver",
                                type: .driverExtension,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writePlist(SRCROOT.join("Info.plist"), .plDict([
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)"),
                "CFBundleName": .plString("$(PRODUCT_NAME)"),
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("foo.c")) { contents in
                contents <<< "int main() { return 0; }\n"
            }

            // macOS 10.15 / DriverKit 19.0 required Info.plists to always be in XML format, so Swift Build overrides the Info.plist format for backwards compatibility.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDKROOT": "driverkit", "DRIVERKIT_DEPLOYMENT_TARGET": "19.0"]), runDestination: .macOS, persistent: true) { results in
                let (_, format) = try PropertyList.fromPathWithFormat(SRCROOT.join("build/Debug-driverkit/Driver.dext/Info.plist"), fs: tester.fs)
                #expect(format == .xml)
            }

            // macOS 11.0 / DriverKit 20.0 switched from kextd to KernelManagement which added support for reading the binary format.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["SDKROOT": "driverkit", "DRIVERKIT_DEPLOYMENT_TARGET": "20.0"]), runDestination: .macOS, persistent: true) { results in
                let (_, format) = try PropertyList.fromPathWithFormat(SRCROOT.join("build/Debug-driverkit/Driver.dext/Info.plist"), fs: tester.fs)
                #expect(format == .binary)
            }
        }
    }
}
