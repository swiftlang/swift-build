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
import SWBProtocol
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct DeviceFamilyBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func targetedDeviceFamilyFiltering_macOS() async throws {

        // Check the defaults
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: nil, expectedIdioms: ["mac"])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: nil, expectedIdioms: ["ipad", "mac"])

        // Check the expected values for the platform
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "2", expectedIdioms: ["ipad"], unexpectedIdioms: ["mac", "iphone"])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "6", expectedIdioms: ["mac"], unexpectedIdioms: ["ipad", "iphone"])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "2,6", expectedIdioms: ["ipad", "mac"], unexpectedIdioms: ["iphone"])

        // Check that multiple values filter down
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: "1,2,3,4,5", expectedIdioms: ["mac"], unexpectedIdioms: ["iphone", "ipad", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: "1,2,3,4,5,6", expectedIdioms: ["mac"], unexpectedIdioms: ["iphone", "ipad", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "1,2,3,4,5,6", expectedIdioms: ["ipad", "mac"], unexpectedIdioms: ["iphone", "tv", "watch"])

        // macOS has no idioms, so we should expect the mac idiom no matter what when building for macOS
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: nil, expectedIdioms: ["mac"], unexpectedIdioms: ["iphone", "ipad", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: "", expectedIdioms: ["mac"], unexpectedIdioms: ["iphone", "ipad", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: "1,2", expectedIdioms: ["mac"], unexpectedIdioms: ["iphone", "ipad", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: "1,2,3,4,5", expectedIdioms: ["mac"], unexpectedIdioms: ["iphone", "ipad", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macOS, targetedDeviceFamily: "1,2,3,4,5,6", expectedIdioms: ["mac"], unexpectedIdioms: ["iphone", "ipad", "tv", "watch"])

        // ...except when building for macCatalyst
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: nil, expectedIdioms: ["ipad", "mac"], unexpectedIdioms: ["iphone", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "", expectedIdioms: ["ipad", "mac"], unexpectedIdioms: ["iphone", "tv", "watch"], expectedWarnings: ["TARGETED_DEVICE_FAMILY value does not contain any device family values compatible with the Mac Catalyst platform. Please add one or more of the following values to the TARGETED_DEVICE_FAMILY build setting to indicate the device families supported by this target: '2' (indicating 'iPad'), '6' (indicating 'Mac')."])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "1,2", expectedIdioms: ["ipad"], unexpectedIdioms: ["mac", "iphone", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "1,2,3,4,5", expectedIdioms: ["ipad"], unexpectedIdioms: ["mac", "iphone", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "1,2,3,4,5,6", expectedIdioms: ["ipad", "mac"], unexpectedIdioms: ["iphone", "tv", "watch"])

        // Check what happens with missing values
        try await deviceFamilyBuildOperationTester(destination: .macCatalyst, targetedDeviceFamily: "3,4", expectedIdioms: ["ipad", "mac"], unexpectedIdioms: ["iphone", "tv", "watch"], expectedWarnings: ["TARGETED_DEVICE_FAMILY value (3,4) does not contain any device family values compatible with the Mac Catalyst platform. Please add one or more of the following values to the TARGETED_DEVICE_FAMILY build setting to indicate the device families supported by this target: '2' (indicating 'iPad'), '6' (indicating 'Mac')."])
    }

    @Test(.requireSDKs(.iOS))
    func targetedDeviceFamilyFiltering_iOS() async throws {

        // Check the defaults
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: nil, expectedIdioms: ["iphone"], unexpectedIdioms: ["ipad"])

        // Check the expected values for the platform
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: "1", expectedIdioms: ["iphone"], unexpectedIdioms: ["ipad"])
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: "2", expectedIdioms: ["ipad"], unexpectedIdioms: ["iphone"])
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: "1,2", expectedIdioms: ["iphone", "ipad"])

        // Check that multiple values filter down
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: "1,2,3,4,5,6", expectedIdioms: ["iphone", "ipad"], unexpectedIdioms: ["mac", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: "1,3,4,5,6", expectedIdioms: ["iphone"], unexpectedIdioms: ["mac", "ipad", "tv", "watch"])
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: "2,3,4,5,6", expectedIdioms: ["ipad"], unexpectedIdioms: ["mac", "iphone", "tv", "watch"])

        // Check what happens with missing values
        try await deviceFamilyBuildOperationTester(destination: .iOS, targetedDeviceFamily: "3,4", expectedIdioms: ["iphone", "ipad"], unexpectedIdioms: ["mac", "tv", "watch"], expectedWarnings: ["TARGETED_DEVICE_FAMILY value (3,4) does not contain any device family values compatible with the iOS platform. Please add one or more of the following values to the TARGETED_DEVICE_FAMILY build setting to indicate the device families supported by this target: '1' (indicating 'iPhone'), '2' (indicating 'iPad')."])
    }

    @Test(.requireSDKs(.tvOS))
    func targetedDeviceFamilyFiltering_tvOS() async throws {

        // Check the defaults
        try await deviceFamilyBuildOperationTester(destination: .tvOS, targetedDeviceFamily: nil, expectedIdioms: ["tv"])

        // Check the expected values for the platform
        try await deviceFamilyBuildOperationTester(destination: .tvOS, targetedDeviceFamily: "3", expectedIdioms: ["tv"])
        try await deviceFamilyBuildOperationTester(destination: .tvOS, targetedDeviceFamily: "3,5", expectedIdioms: ["tv"])

        // Check that multiple values filter down
        try await deviceFamilyBuildOperationTester(destination: .tvOS, targetedDeviceFamily: "1,2,3,4,5,6,7", expectedIdioms: ["tv"], unexpectedIdioms: ["mac", "iphone", "ipad", "watch", "vision"])

        // Check what happens with missing values
        try await deviceFamilyBuildOperationTester(destination: .tvOS, targetedDeviceFamily: "1,2,4", expectedIdioms: ["tv"], unexpectedIdioms: ["mac", "iphone", "ipad", "watch"], expectedWarnings: ["TARGETED_DEVICE_FAMILY value (1,2,4) does not contain any device family values compatible with the tvOS platform. Please add the value '3' to the TARGETED_DEVICE_FAMILY build setting to indicate that this target supports the 'Apple TV' device family."])
    }

    @Test(.requireSDKs(.watchOS))
    func targetedDeviceFamilyFiltering_watchOS() async throws {

        // Check the defaults
        try await deviceFamilyBuildOperationTester(destination: .watchOS, targetedDeviceFamily: nil, expectedIdioms: ["watch"])

        // Check the expected values for the platform
        try await deviceFamilyBuildOperationTester(destination: .watchOS, targetedDeviceFamily: "4", expectedIdioms: ["watch"])

        // Check that multiple values filter down
        try await deviceFamilyBuildOperationTester(destination: .watchOS, targetedDeviceFamily: "1,2,3,4,5,6,7", expectedIdioms: ["watch"], unexpectedIdioms: ["mac", "iphone", "ipad", "tv", "vision"])

        // Check what happens with missing values
        try await deviceFamilyBuildOperationTester(destination: .watchOS, targetedDeviceFamily: "1,2,3", expectedIdioms: ["watch"], unexpectedIdioms: ["mac", "iphone", "ipad", "tv"], expectedWarnings: ["TARGETED_DEVICE_FAMILY value (1,2,3) does not contain any device family values compatible with the watchOS platform. Please add the value '4' to the TARGETED_DEVICE_FAMILY build setting to indicate that this target supports the 'Apple Watch' device family."])
    }

    @Test(.requireSDKs(.xrOS))
    func targetedDeviceFamilyFiltering_visionOS() async throws {
        // Check the defaults
        try await deviceFamilyBuildOperationTester(destination: .xrOS, targetedDeviceFamily: nil, expectedIdioms: ["vision"])

        // Check the expected values for the platform
        try await deviceFamilyBuildOperationTester(destination: .xrOS, targetedDeviceFamily: "7", expectedIdioms: ["vision"])

        // Check that multiple values filter down
        try await deviceFamilyBuildOperationTester(destination: .xrOS, targetedDeviceFamily: "1,2,3,4,5,6,7", expectedIdioms: ["vision"], unexpectedIdioms: ["mac", "iphone", "ipad", "tv", "watch"])

        // Check what happens with missing values
        try await deviceFamilyBuildOperationTester(destination: .xrOS, targetedDeviceFamily: "1,2,3", expectedIdioms: ["vision"], unexpectedIdioms: ["mac", "iphone", "ipad", "tv", "watch"], expectedWarnings: ["TARGETED_DEVICE_FAMILY value (1,2,3) does not contain any device family values compatible with the visionOS platform. Please add the value '7' to the TARGETED_DEVICE_FAMILY build setting to indicate that this target supports the 'Apple Vision' device family."])
    }

    /// Tests `TARGETED_DEVICE_FAMILY` filtering in conjunction with some Mac Catalyst specifics such as deployment target and variance between product types.
    @Test(.requireSDKs(.iOS, .macOS)) // rdar://94648014 (Mac Catalyst builds may still attempt to use the iOS SDK)
    func targetedDeviceFamilyFilteringMacCatalyst() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources",
                    path: "",
                    children: [
                        TestFile("Assets.xcassets"),
                        TestFile("Info.plist")
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "",
                            "IPHONEOS_DEPLOYMENT_TARGET": "13.1",
                            "SDKROOT": "iphoneos",
                            "SUPPORTS_MACCATALYST": "YES",
                            "TARGETED_DEVICE_FAMILY": "2,6",
                            "VERSIONING_SYSTEM": "apple-generic"
                        ]
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "INFOPLIST_FILE": "$(SRCROOT)/Info.plist",
                                ]
                            )
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["Assets.xcassets"])
                        ],
                        dependencies: ["Appex", "Framework"]
                    ),
                    TestStandardTarget(
                        "Appex",
                        type: .applicationExtension,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "INFOPLIST_FILE": "$(SRCROOT)/Info.plist",
                                ]
                            )
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["Assets.xcassets"])
                        ]
                    ),
                    TestStandardTarget(
                        "Framework",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "INFOPLIST_FILE": "$(SRCROOT)/Info.plist",
                                ]
                            )
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["Assets.xcassets"])
                        ]
                    )
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let SRCROOT = tmpDirPath

            try await tester.fs.writePlist(SRCROOT.join("Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            try await tester.fs.writeAssetCatalog(SRCROOT.join("Assets.xcassets"), .root, .appIcon("AppIcon"))

            func assertUIDeviceFamily(targetName: String, _ values: [Int], file: StaticString = #filePath, line: UInt = #line) throws {
                let path: String
                switch targetName {
                case "App":
                    path = "App.app/Contents"
                case "Appex":
                    path = "Appex.appex/Contents"
                case "Framework":
                    path = "Framework.framework/Versions/A/Resources"
                default:
                    throw StubError.error("Unknown target '\(targetName)'")
                }

                #expect(try PropertyList.fromPath(tmpDirPath.join("build/Debug-maccatalyst/\(path)/Info.plist"), fs: tester.fs).dictValue?["UIDeviceFamily"] == PropertyListItem.plArray(values.map { .plInt($0) }))
            }

            func checkEverything(_ results: BuildOperationTester.BuildResults) throws {
                results.checkNoErrors()

                results.checkTask(.matchTargetName("App"), .matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "ipad", "--target-device", "mac"])
                }

                results.checkTask(.matchTargetName("Appex"), .matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "ipad", "--target-device", "mac"])
                }

                results.checkTask(.matchTargetName("Framework"), .matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "ipad", "--target-device", "mac"])
                }

                try assertUIDeviceFamily(targetName: "App", [2, 6])
                try assertUIDeviceFamily(targetName: "Appex", [2, 6])
                try assertUIDeviceFamily(targetName: "Framework", [2, 6])
            }

            func checkMacOnly(_ results: BuildOperationTester.BuildResults) throws {
                results.checkNoErrors()

                results.checkTask(.matchTargetName("App"), .matchRuleType("CompileAssetCatalog")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "mac"])
                    task.checkCommandLineDoesNotContain("ipad")
                }

                results.checkTask(.matchTargetName("Appex"), .matchRuleType("CompileAssetCatalog")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "mac"])
                    task.checkCommandLineDoesNotContain("ipad")
                }

                results.checkTask(.matchTargetName("Framework"), .matchRuleType("CompileAssetCatalog")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "ipad", "--target-device", "mac"])
                }

                try assertUIDeviceFamily(targetName: "App", [6])
                try assertUIDeviceFamily(targetName: "Appex", [2, 6])
                try assertUIDeviceFamily(targetName: "Framework", [2, 6])
            }

            // When deploying back, we get everything by default
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macCatalyst, body: checkEverything)

            // When deploying to 14, we lose ipad assets in apps only, not in appexts/frameworks
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["IPHONEOS_DEPLOYMENT_TARGET": "14.0"]), runDestination: .macCatalyst) { results in
                results.checkNoErrors()

                results.checkTask(.matchTargetName("App"), .matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "mac"])
                    task.checkCommandLineDoesNotContain("ipad")
                }

                results.checkTask(.matchTargetName("Appex"), .matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "ipad", "--target-device", "mac"])
                }

                results.checkTask(.matchTargetName("Framework"), .matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkCommandLineContainsUninterrupted(["--target-device", "ipad", "--target-device", "mac"])
                }

                try assertUIDeviceFamily(targetName: "App", [6])
                try assertUIDeviceFamily(targetName: "Appex", [2, 6])
                try assertUIDeviceFamily(targetName: "Framework", [2, 6])
            }
        }
    }
}
