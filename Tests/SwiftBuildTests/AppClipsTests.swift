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

import Foundation
import SWBTestSupport
import SwiftBuild
import SwiftBuildTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct AppClipsTests: CoreBasedTests {
    @Test(.requireSDKs(.iOS))
    func appClips_iOS() async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withTester(TestProject.appClip(sourceRoot: tmpDir, fs: localFS), fs: localFS) { tester in
                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .iOS, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-"]), delegate: AppClipsBuildOperationDelegate(isEnterpriseTeam: false)) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()

                    results.checkFileExists(tmpDir.join("build/Debug-iphoneos/Foo.app/AppClips/BarClip.app/BarClip"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphoneos/Foo.app/AppClips/BarClip.app/Info.plist"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphoneos/Foo.app/AppClips/BarClip.app/PkgInfo"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphoneos/Foo.app/Foo"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphoneos/Foo.app/Info.plist"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphoneos/Foo.app/PkgInfo"))

                    try await results.checkEntitlements(.signed, tmpDir.join("build/Debug-iphoneos/Foo.app/Foo")) { entitlements in
                        #expect(entitlements?["application-identifier"] == .plString("com.foo.app"))
                    }

                    try await results.checkNoEntitlements(.simulated, tmpDir.join("build/Debug-iphoneos/Foo.app/Foo"))

                    try await results.checkEntitlements(.signed, tmpDir.join("build/Debug-iphoneos/Foo.app/AppClips/BarClip.app/BarClip")) { entitlements in
                        #expect(entitlements?["com.apple.developer.on-demand-install-capable"] == .plBool(true))
                        #expect(entitlements?["com.apple.developer.parent-application-identifiers"] == .plArray([.plString("com.foo.app")]))
                    }

                    try await results.checkNoEntitlements(.simulated, tmpDir.join("build/Debug-iphoneos/Foo.app/AppClips/BarClip.app/BarClip"))
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func appClips_iOSSimulator() async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withTester(TestProject.appClip(sourceRoot: tmpDir, fs: localFS), fs: localFS) { tester in
                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .iOSSimulator, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-"]), delegate: AppClipsBuildOperationDelegate(isEnterpriseTeam: false)) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()

                    results.checkFileExists(tmpDir.join("build/Debug-iphonesimulator/Foo.app/AppClips/BarClip.app/BarClip"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphonesimulator/Foo.app/AppClips/BarClip.app/Info.plist"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphonesimulator/Foo.app/AppClips/BarClip.app/PkgInfo"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphonesimulator/Foo.app/Foo"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphonesimulator/Foo.app/Info.plist"))
                    results.checkFileExists(tmpDir.join("build/Debug-iphonesimulator/Foo.app/PkgInfo"))

                    try await results.checkEntitlements(.simulated, tmpDir.join("build/Debug-iphonesimulator/Foo.app/Foo")) { entitlements in
                        #expect(entitlements?["application-identifier"] == .plString("com.foo.app"))
                    }

                    try await results.checkEntitlements(.signed, tmpDir.join("build/Debug-iphonesimulator/Foo.app/Foo")) { entitlements in
                        #expect(entitlements?["get-task-allow"] == .plBool(true))
                    }

                    try await results.checkEntitlements(.simulated, tmpDir.join("build/Debug-iphonesimulator/Foo.app/AppClips/BarClip.app/BarClip")) { entitlements in
                        #expect(entitlements?["com.apple.developer.on-demand-install-capable"] == .plBool(true))
                        #expect(entitlements?["com.apple.developer.parent-application-identifiers"] == .plArray([.plString("com.foo.app")]))
                    }

                    try await results.checkEntitlements(.signed, tmpDir.join("build/Debug-iphonesimulator/Foo.app/AppClips/BarClip.app/BarClip")) { entitlements in
                        #expect(entitlements?["get-task-allow"] == .plBool(true))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func appClips_MacCatalyst() async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withTester(TestProject.appClip(sourceRoot: tmpDir, fs: localFS), fs: localFS) { tester in
                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .macCatalyst, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-"]), delegate: AppClipsBuildOperationDelegate(isEnterpriseTeam: false)) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()

                    results.checkFileDoesNotExist(tmpDir.join("build/Debug-maccatalyst/Foo.app/Contents/AppClips/BarClip.app"))
                    results.checkFileExists(tmpDir.join("build/Debug-maccatalyst/Foo.app/Contents/MacOS/Foo"))
                    results.checkFileExists(tmpDir.join("build/Debug-maccatalyst/Foo.app/Contents/Info.plist"))
                    results.checkFileExists(tmpDir.join("build/Debug-maccatalyst/Foo.app/Contents/PkgInfo"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS), arguments: [true, false])
    func appClips_MacCatalyst_Error(appClipSupportsMacCatalyst: Bool) async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withTester(TestProject.appClip(sourceRoot: tmpDir, fs: localFS, appClipPlatformFilters: [], appClipSupportsMacCatalyst: appClipSupportsMacCatalyst), fs: localFS) { tester in
                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .macCatalyst, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-"]), delegate: AppClipsBuildOperationDelegate(isEnterpriseTeam: false)) { results in

                    if appClipSupportsMacCatalyst {
                        results.checkError(.equal("App Clips are not available when building for Mac Catalyst."))
                        results.checkNoFailedTasks()
                    } else {
                        results.checkError(.equal("Your target is built for macOS but contains embedded content built for the iOS platform (BarClip.app), which is not allowed."))
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func appClips_EnterpriseTeamError() async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withTester(TestProject.appClip(sourceRoot: tmpDir, fs: localFS), fs: localFS) { tester in
                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .iOS, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-"]), delegate: AppClipsBuildOperationDelegate(isEnterpriseTeam: true)) { results in
                    results.checkWarning(.equal("App Clips are not supported when signing with an enterprise team."))
                }
            }
        }
    }

    final class AppClipsBuildOperationDelegate: SWBPlanningOperationDelegate {
        let isEnterpriseTeam: Bool

        init(isEnterpriseTeam: Bool) {
            self.isEnterpriseTeam = isEnterpriseTeam
        }

        // Simulated implementation of the provisioning system which ad-hoc signs with the product type + project entitlements
        // FIXME: Find a way to call the real thing, perhaps in the future this is `xcsigningtool`
        func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
            let signedEntitlements = provisioningSourceData.entitlementsDestination == "Signature"
            ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
            : [:]

            let simulatedEntitlements = provisioningSourceData.entitlementsDestination == "__entitlements"
            ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
            : [:]

            return SWBProvisioningTaskInputs(identityHash: "-", identityName: "-", profileName: nil, profileUUID: nil, profilePath: nil, designatedRequirements: nil, signedEntitlements: signedEntitlements.merging(provisioningSourceData.sdkRoot.contains("simulator") ? ["get-task-allow": .plBool(true)] : [:], uniquingKeysWith: { _, new  in new }), simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: nil, teamIdentifierPrefix: nil, isEnterpriseTeam: isEnterpriseTeam, keychainPath: nil, errors: [], warnings: [])
        }

        func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
            .deferred
        }
    }
}
