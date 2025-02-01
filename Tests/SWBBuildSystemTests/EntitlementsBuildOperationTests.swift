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

import SWBBuildSystem
import SWBCore
import struct SWBProtocol.RunDestinationInfo
import struct SWBProtocol.TargetDescription
import struct SWBProtocol.TargetDependencyRelationship
import SWBTestSupport
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct EntitlementsBuildOperationTests: CoreBasedTests {
    /// Test that the `ProcessProductEntitlementsTaskAction` embeds the App Sandbox entitlement when asked to do so via a build setting.
    @Test(.requireSDKs(.macOS))
    func macOSAppSandboxEnabledEntitlement() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_APP_SANDBOX": "YES",
                    "SDKROOT": "macosx"
                ]
            )
            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                "com.apple.security.app-sandbox": "1",
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` does not embed the App Sandbox entitlement when asked not to do so via a build setting.
    @Test(.requireSDKs(.macOS))
    func macOSAppSandboxEnabledEntitlementOff() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_APP_SANDBOX": "NO",
                    "SDKROOT": "macosx"
                ]
            )
            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` embeds the App Sandbox "read-only" access to file access entitlements when asked to do so via a build setting.
    @Test(.requireSDKs(.macOS))
    func macOSUserSelectedFilesReadOnlyEntitlement() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_APP_SANDBOX": "YES",
                    "ENABLE_USER_SELECTED_FILES": "readonly",
                    "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "readonly",
                    "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "readonly",
                    "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "readonly",
                    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "readonly",
                    "SDKROOT": "macosx"
                ]
            )
            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                "com.apple.security.app-sandbox": "1",
                "com.apple.security.files.user-selected.read-only": "1",
                "com.apple.security.assets.movies.read-only": "1",
                "com.apple.security.assets.music.read-only": "1",
                "com.apple.security.assets.pictures.read-only": "1",
                "com.apple.security.files.downloads.read-only": "1",
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` embeds the App Sandbox "read/write access to user-selected files" entitlement when asked to do so via a build setting.
    @Test(.requireSDKs(.macOS))
    func macOSUserSelectedFilesReadWriteEntitlement() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_APP_SANDBOX": "YES",
                    "ENABLE_USER_SELECTED_FILES": "readwrite",
                    "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "readwrite",
                    "SDKROOT": "macosx"
                ]
            )
            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                "com.apple.security.app-sandbox": "1",
                "com.apple.security.files.user-selected.read-write": "1",
                "com.apple.security.assets.movies.read-write": "1",
                "com.apple.security.assets.music.read-write": "1",
                "com.apple.security.assets.pictures.read-write": "1",
                "com.apple.security.files.downloads.read-write": "1",
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` embeds no App Sandbox or Hardened Runtime dependent entitlement when not asked to do so via a build setting.
    @Test(.requireSDKs(.macOS))
    func macOSEmptyBuildSettingsBasedEntitlements() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_APP_SANDBOX": "YES",
                    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "",
                    "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "",
                    "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "",
                    "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "",
                    "ENABLE_INCOMING_NETWORK_CONNECTIONS": "",
                    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "",
                    "ENABLE_USER_SELECTED_FILES": "",
                    "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "",
                    "ENABLE_RESOURCE_ACCESS_BLUETOOTH": "",
                    "ENABLE_RESOURCE_ACCESS_CALENDARS": "",
                    "ENABLE_RESOURCE_ACCESS_CAMERA": "",
                    "ENABLE_RESOURCE_ACCESS_CONTACTS": "",
                    "ENABLE_RESOURCE_ACCESS_LOCATION": "",
                    "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": "",
                    "ENABLE_RESOURCE_ACCESS_USB": "",
                    "ENABLE_RESOURCE_ACCESS_PRINTING": "",
                    "SDKROOT": "macosx"
                ]
            )

            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                "com.apple.security.app-sandbox": "1",
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` embeds entitlements that are settable through build settings and dependent on App Sandbox being enabled.
    @Test(.requireSDKs(.macOS))
    func macOSAppSandboxEnabledEntitlements() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_APP_SANDBOX": "YES",
                    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "readonly",
                    "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "readonly",
                    "ENABLE_INCOMING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "YES",
                    "ENABLE_RESOURCE_ACCESS_BLUETOOTH": "YES",
                    "ENABLE_RESOURCE_ACCESS_CALENDARS": "YES",
                    "ENABLE_RESOURCE_ACCESS_CAMERA": "YES",
                    "ENABLE_RESOURCE_ACCESS_CONTACTS": "YES",
                    "ENABLE_RESOURCE_ACCESS_LOCATION": "YES",
                    "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": "YES",
                    "ENABLE_RESOURCE_ACCESS_USB": "YES",
                    "ENABLE_RESOURCE_ACCESS_PRINTING": "YES",
                    "SDKROOT": "macosx"
                ]
            )

            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                "com.apple.security.app-sandbox": "1",
                "com.apple.security.device.audio-input": "1",
                "com.apple.security.device.bluetooth": "1",
                "com.apple.security.personal-information.calendars": "1",
                "com.apple.security.device.camera": "1",
                "com.apple.security.personal-information.addressbook": "1",
                "com.apple.security.personal-information.location": "1",
                "com.apple.security.personal-information.photos-library": "1",
                "com.apple.security.files.downloads.read-write": "1",
                "com.apple.security.assets.pictures.read-only": "1",
                "com.apple.security.assets.music.read-write": "1",
                "com.apple.security.assets.movies.read-only": "1",
                "com.apple.security.network.client": "1",
                "com.apple.security.network.server": "1",
                "com.apple.security.print": "1",
                "com.apple.security.device.usb": "1"
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` does not embed build settings based entitlements that are dependent on App Sandbox being enabled, when App Sandbox is disabled.
    @Test(.requireSDKs(.macOS))
    func macOSAppSandboxEnabledEntitlementsWithSandboxDisabled() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_APP_SANDBOX": "NO",
                    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "readonly",
                    "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "readonly",
                    "ENABLE_INCOMING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "YES",
                    "ENABLE_RESOURCE_ACCESS_BLUETOOTH": "YES",
                    "ENABLE_RESOURCE_ACCESS_CALENDARS": "YES",
                    "ENABLE_RESOURCE_ACCESS_CAMERA": "YES",
                    "ENABLE_RESOURCE_ACCESS_CONTACTS": "YES",
                    "ENABLE_RESOURCE_ACCESS_LOCATION": "YES",
                    "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": "YES",
                    "ENABLE_RESOURCE_ACCESS_USB": "YES",
                    "ENABLE_RESOURCE_ACCESS_PRINTING": "YES",
                    "SDKROOT": "macosx"
                ]
            )

            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` embeds entitlements that are settable through build settings and dependent on Hardened Runtime being enabled.
    @Test(.requireSDKs(.macOS))
    func macOSHardenedRuntimeEnabledEntitlements() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "readonly",
                    "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "readonly",
                    "ENABLE_INCOMING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "YES",
                    "ENABLE_RESOURCE_ACCESS_BLUETOOTH": "YES",
                    "ENABLE_RESOURCE_ACCESS_CALENDARS": "YES",
                    "ENABLE_RESOURCE_ACCESS_CAMERA": "YES",
                    "ENABLE_RESOURCE_ACCESS_CONTACTS": "YES",
                    "ENABLE_RESOURCE_ACCESS_LOCATION": "YES",
                    "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": "YES",
                    "SDKROOT": "macosx"
                ]
            )

            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                "com.apple.security.device.audio-input": "1",
                "com.apple.security.device.bluetooth": "1",
                "com.apple.security.personal-information.calendars": "1",
                "com.apple.security.device.camera": "1",
                "com.apple.security.personal-information.addressbook": "1",
                "com.apple.security.personal-information.location": "1",
                "com.apple.security.personal-information.photos-library": "1",
                "com.apple.security.files.downloads.read-write": "1",
                "com.apple.security.assets.pictures.read-only": "1",
                "com.apple.security.assets.music.read-write": "1",
                "com.apple.security.assets.movies.read-only": "1",
                "com.apple.security.network.client": "1",
                "com.apple.security.network.server": "1",
            ])
        }
    }

    /// Test that the `ProcessProductEntitlementsTaskAction` does not embed build settings based entitlements that are dependent on Hardened Runtime being enabled, when Hardened Runtime is disabled.
    @Test(.requireSDKs(.macOS))
    func macOSHardenedRuntimeEnabledEntitlementsWithHardenedRuntimeDisabled() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_HARDENED_RUNTIME": "NO",
                    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_PICTURE_FOLDER": "readonly",
                    "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "readwrite",
                    "ENABLE_FILE_ACCESS_MOVIES_FOLDER": "readonly",
                    "ENABLE_INCOMING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
                    "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "YES",
                    "ENABLE_RESOURCE_ACCESS_BLUETOOTH": "YES",
                    "ENABLE_RESOURCE_ACCESS_CALENDARS": "YES",
                    "ENABLE_RESOURCE_ACCESS_CAMERA": "YES",
                    "ENABLE_RESOURCE_ACCESS_CONTACTS": "YES",
                    "ENABLE_RESOURCE_ACCESS_LOCATION": "YES",
                    "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": "YES",
                    "SDKROOT": "macosx"
                ]
            )

            try await buildTestBinaryAndValidateEntitlements(testWorkspace: testWorkspace, expectedEntitlements: [
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
            ])
        }
    }

    @Test(.requireSDKs(.iOS))
    func simulatorEntitlementsSections() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("main.c")
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphonesimulator",
                            ]
                        )
                    ],
                    targets: [
                        TestStandardTarget(
                            "App",
                            type: .application,
                            buildPhases: [
                                TestSourcesBuildPhase(["main.c"])
                            ]
                        )
                    ]
                )
            ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main(){}"
            }

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let entitlements: PropertyListItem = [
                // Specify jsut the baseline entitlements, since other entitlements should be added via build settings.
                "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
            ]
            let provisioningInputs = ["App": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: entitlements, simulatedEntitlements: entitlements)]

            try await tester.checkBuild(parameters: parameters, runDestination: .iOSSimulator, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                try await results.checkEntitlements(.simulated, testWorkspace.sourceRoot.join("aProject/build/Debug-iphonesimulator/App.app/App")) { plist in
                    #expect(plist == ["com.apple.application-identifier": .plString("$(AppIdentifierPrefix)$(CFBundleIdentifier)")])
                }
            }
        }
    }

    // MARK: - Shared Helpers

    private func entitlementsTestWorkspace(sourceRoot: Path, buildSettings: [String: String]) -> TestWorkspace {
        return TestWorkspace(
            "Test",
            sourceRoot: sourceRoot.join("Test"),
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            // App sources
                            TestFile("main.c"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: buildSettings
                    )],
                    targets: [
                        TestStandardTarget(
                            "App",
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    "main.c",
                                ]),
                                TestFrameworksBuildPhase([
                                ]),
                            ]
                        )
                    ]
                )
            ]
        )
    }

    private func buildTestBinaryAndValidateEntitlements(testWorkspace: TestWorkspace, expectedEntitlements: [String: PropertyListItem]) async throws {
        let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

        // Write the file data.
        try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
            stream <<< "int main(){}"
        }

        try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict([:]))

        // Perform the initial for-launch build.
        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let entitlements: PropertyListItem = [
            // Specify jsut the baseline entitlements, since other entitlements should be added via build settings.
            "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
        ]
        let provisioningInputs = ["App": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: entitlements, simulatedEntitlements: [:])]
        try await tester.checkBuild(parameters: parameters, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
            // Make sure that the entitlements processing task ran.
            let entitlementsTask = try results.checkTask(.matchRuleType("ProcessProductPackaging")) { task throws in task }
            results.check(contains: .taskHadEvent(entitlementsTask, event: .started))

            results.checkNoDiagnostics()

            #expect(entitlementsTask.additionalOutput.count == 3)

            let composedEntitlements = try PropertyList.fromString(entitlementsTask.additionalOutput[2])
            #expect(composedEntitlements == .plDict(expectedEntitlements))
        }
    }
}
