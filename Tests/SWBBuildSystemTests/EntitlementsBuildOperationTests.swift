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

import SWBBuildSystem
import SWBCore
import struct SWBProtocol.RunDestinationInfo
import struct SWBProtocol.TargetDescription
import struct SWBProtocol.TargetDependencyRelationship
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SwiftBuildTestSupport

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
                    "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES": "",
                    "RUNTIME_EXCEPTION_ALLOW_JIT": "",
                    "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY": "",
                    "AUTOMATION_APPLE_EVENTS": "",
                    "RUNTIME_EXCEPTION_DEBUGGING_TOOL": "",
                    "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION": "",
                    "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "",
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
                    "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_JIT": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY": "YES",
                    "AUTOMATION_APPLE_EVENTS": "YES",
                    "RUNTIME_EXCEPTION_DEBUGGING_TOOL": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "YES",
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
                "com.apple.security.automation.apple-events": "1",
                "com.apple.security.cs.allow-dyld-environment-variables": "1",
                "com.apple.security.cs.allow-jit": "1",
                "com.apple.security.cs.allow-unsigned-executable-memory": "1",
                "com.apple.security.cs.debugger": "1",
                "com.apple.security.cs.disable-executable-page-protection": "1",
                "com.apple.security.cs.disable-library-validation": "1",
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

    /// Test that the `ProcessProductEntitlementsTaskAction` does not embed build settings that only apply to macOS.
    @Test(.requireSDKs(.iOS))
    func iOSAppSandboxAndHardnedRuntimeBuildSettingEnabled() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_JIT": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY": "YES",
                    "AUTOMATION_APPLE_EVENTS": "YES",
                    "RUNTIME_EXCEPTION_DEBUGGING_TOOL": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "YES",
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
                    "SDKROOT": "iphoneos"
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
                    "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_JIT": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY": "YES",
                    "AUTOMATION_APPLE_EVENTS": "YES",
                    "RUNTIME_EXCEPTION_DEBUGGING_TOOL": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "YES",
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
                "com.apple.security.automation.apple-events": "1",
                "com.apple.security.cs.allow-dyld-environment-variables": "1",
                "com.apple.security.cs.allow-jit": "1",
                "com.apple.security.cs.allow-unsigned-executable-memory": "1",
                "com.apple.security.cs.debugger": "1",
                "com.apple.security.cs.disable-executable-page-protection": "1",
                "com.apple.security.cs.disable-library-validation": "1",
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

    /// Test that the `ProcessProductEntitlementsTaskAction` embeds entitlements that are settable through build settings and dependent on Hardened Runtime being enabled. Emitting the correct warnings as the entitlements and build settings are different.
    @Test(.requireSDKs(.macOS))
    func macOSHardenedRuntimeEnabledEntitlementsWithConflict() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = entitlementsTestWorkspace(
                sourceRoot: tmpDirPath,
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES": "YES",
                    "RUNTIME_EXCEPTION_ALLOW_JIT": "NO",
                    "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY": "YES",
                    "AUTOMATION_APPLE_EVENTS": "YES",
                    "RUNTIME_EXCEPTION_DEBUGGING_TOOL": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION": "YES",
                    "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "YES",
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

            try await buildTestBinaryAndValidateEntitlements(
                testWorkspace: testWorkspace,
                expectedEntitlements: [
                    "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                    "com.apple.security.automation.apple-events": "1",
                    "com.apple.security.cs.allow-dyld-environment-variables": "1",
                    "com.apple.security.cs.allow-jit": "1",
                    "com.apple.security.cs.allow-unsigned-executable-memory": "1",
                    "com.apple.security.cs.debugger": "1",
                    "com.apple.security.cs.disable-executable-page-protection": "1",
                    "com.apple.security.cs.disable-library-validation": "1",
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
                ],
                signedEntitlements: [
                    "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                    "com.apple.security.automation.apple-events": .plBool(true),
                    "com.apple.security.cs.allow-dyld-environment-variables": .plBool(true),
                    "com.apple.security.cs.allow-jit": .plBool(true),
                    "com.apple.security.cs.allow-unsigned-executable-memory": .plBool(true),
                    "com.apple.security.cs.debugger": .plBool(true),
                    "com.apple.security.cs.disable-executable-page-protection": .plBool(true),
                    "com.apple.security.cs.disable-library-validation": .plBool(true),
                    "com.apple.security.device.audio-input": .plBool(false),
                    "com.apple.security.device.bluetooth": .plBool(true),
                    "com.apple.security.personal-information.calendars": .plBool(true),
                    "com.apple.security.device.camera": .plBool(true),
                    "com.apple.security.personal-information.addressbook": .plBool(true),
                    "com.apple.security.personal-information.location": .plBool(true),
                    "com.apple.security.personal-information.photos-library": .plBool(true),
                    "com.apple.security.files.downloads.read-write": .plBool(true),
                    "com.apple.security.assets.pictures.read-only": .plBool(true),
                    "com.apple.security.assets.music.read-write": .plBool(true),
                    "com.apple.security.assets.movies.read-only": .plBool(false),
                    "com.apple.security.network.client": .plBool(true),
                    "com.apple.security.network.server": .plBool(true),
                ], expectedWarnings: SWBFeatureFlag.enableAppSandboxConflictingValuesEmitsWarning.value ? [
                    "The \'ENABLE_RESOURCE_ACCESS_AUDIO_INPUT\' build setting is set to \'YES\', but entitlement \'com.apple.security.device.audio-input\' is set to \'NO\' in your entitlements file.\nTo enable \'ENABLE_RESOURCE_ACCESS_AUDIO_INPUT\', remove the entitlement from your entitlements file.\nTo disable \'ENABLE_RESOURCE_ACCESS_AUDIO_INPUT\', remove the entitlement from your entitlements file and disable \'ENABLE_RESOURCE_ACCESS_AUDIO_INPUT\' in  build settings. (in target \'App\' from project \'aProject\')",
                    "The \'ENABLE_FILE_ACCESS_MOVIES_FOLDER\' build setting is set to \'readOnly\', but entitlement \'com.apple.security.assets.movies.read-only\' is set to \'NO\' in your entitlements file.\nTo enable \'ENABLE_FILE_ACCESS_MOVIES_FOLDER\', remove the entitlement from your entitlements file.\nTo disable \'ENABLE_FILE_ACCESS_MOVIES_FOLDER\', remove the entitlement from your entitlements file and disable \'ENABLE_FILE_ACCESS_MOVIES_FOLDER\' in  build settings. (in target \'App\' from project \'aProject\')",
                    "The \'RUNTIME_EXCEPTION_ALLOW_JIT\' build setting is set to \'NO\', but entitlement \'com.apple.security.cs.allow-jit\' is set to \'YES\' in your entitlements file.\nTo enable \'RUNTIME_EXCEPTION_ALLOW_JIT\', remove the entitlement from your entitlements file, and enable \'RUNTIME_EXCEPTION_ALLOW_JIT\' in build settings.\nTo disable \'RUNTIME_EXCEPTION_ALLOW_JIT\', remove the entitlement from your entitlements file. (in target \'App\' from project \'aProject\')"
                ] : nil
            )

            try await buildTestBinaryAndValidateEntitlements(
                testWorkspace: testWorkspace,
                expectedEntitlements: [
                    "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                    "com.apple.security.automation.apple-events": "1",
                    "com.apple.security.cs.allow-dyld-environment-variables": "1",
                    "com.apple.security.cs.allow-unsigned-executable-memory": "1",
                    "com.apple.security.cs.debugger": "1",
                    "com.apple.security.cs.disable-executable-page-protection": "1",
                    "com.apple.security.cs.disable-library-validation": "1",
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
                ],
                signedEntitlements: [
                    "com.apple.application-identifier": "$(AppIdentifierPrefix)$(CFBundleIdentifier)",
                    "com.apple.security.automation.apple-events": .plBool(true),
                    "com.apple.security.cs.allow-dyld-environment-variables": .plBool(true),
                    "com.apple.security.cs.allow-unsigned-executable-memory": .plBool(true),
                    "com.apple.security.cs.debugger": .plBool(true),
                    "com.apple.security.cs.disable-executable-page-protection": .plBool(true),
                    "com.apple.security.cs.disable-library-validation": .plBool(true),
                    "com.apple.security.device.audio-input": .plBool(true),
                    "com.apple.security.device.bluetooth": .plBool(true),
                    "com.apple.security.personal-information.calendars": .plBool(true),
                    "com.apple.security.device.camera": .plBool(true),
                    "com.apple.security.personal-information.addressbook": .plBool(true),
                    "com.apple.security.personal-information.location": .plBool(true),
                    "com.apple.security.personal-information.photos-library": .plBool(true),
                    "com.apple.security.files.downloads.read-write": .plBool(true),
                    "com.apple.security.assets.pictures.read-only": .plBool(true),
                    "com.apple.security.assets.music.read-write": .plBool(true),
                    "com.apple.security.assets.movies.read-only": .plBool(true),
                    "com.apple.security.network.client": .plBool(true),
                    "com.apple.security.network.server": .plBool(true),
                ]
            )
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
                // Specify just the baseline entitlements, since other entitlements should be added via build settings.
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
                            type: .application,
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

    private func buildTestBinaryAndValidateEntitlements(testWorkspace: TestWorkspace, expectedEntitlements: [String: PropertyListItem], signedEntitlements: [String: PropertyListItem] = [:], expectedWarnings: Set<String>? = nil) async throws {
        let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

        // Write the file data.
        try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
            stream <<< "int main(){}"
        }

        try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict([:]))

        // Perform the initial for-launch build.
        let parameters = BuildParameters(action: .build, configuration: "Debug")

        var entitlements = signedEntitlements
        entitlements["com.apple.application-identifier"] = .plString("$(AppIdentifierPrefix)$(CFBundleIdentifier)")

        let provisioningInputs = ["App": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: PropertyListItem(entitlements), simulatedEntitlements: [:])]
        try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
            // Make sure that the entitlements processing task ran.
            let entitlementsTask = try results.checkTask(.matchRuleType("ProcessProductPackaging")) { task throws in task }
            results.check(contains: .taskHadEvent(entitlementsTask, event: .started))

            if let expectedWarnings {
                let warnings = Set(results.getWarnings())
                #expect(warnings == expectedWarnings)
            } else {
                results.checkNoDiagnostics()
            }

            #expect(entitlementsTask.additionalOutput.count == 3)

            let composedEntitlements = try PropertyList.fromString(entitlementsTask.additionalOutput[2])
            #expect(composedEntitlements == .plDict(expectedEntitlements))
        }
    }
}
