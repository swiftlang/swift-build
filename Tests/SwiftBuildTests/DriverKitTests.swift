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
import SwiftBuildTestSupport
import Testing
import SWBUtil
import SwiftBuild

@Suite
fileprivate struct DriverKitTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS, .driverKit))
    func appWithDriver() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let fs: any FSProxy = localFS

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
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
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
                                        "SDKROOT": "auto",
                                        "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
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
            try await withTester(testWorkspace, fs: fs) { tester in
                let SRCROOT = tmpDirPath.join("Test")

                try fs.createDirectory(SRCROOT.join("aProject"), recursive: true)
                try fs.write(SRCROOT.join("aProject/foo.c"), contents: "int main() { return 0; }")

                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyMac, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES"]), delegate: DriverKitBuildOperationDelegate()) { results in
                    results.checkNoDiagnostics()
                    results.checkNoFailedTasks()

                    try results.checkPropertyListContents(Path("\(tmpDirPath.str)/Test/aProject/build/Debug/App.app/Contents/Info.plist")) { plist in
                        #expect(plist.dictValue?["CFBundleSupportedPlatforms"] == .plArray([.plString("MacOSX")]))
                    }

                    try results.checkPropertyListContents(Path("\(tmpDirPath.str)/Test/aProject/build/Debug/App.app/Contents/Library/SystemExtensions/Driver.dext/Info.plist")) { plist in
                        #expect(plist.dictValue?["CFBundlePackageType"] == .plString("DEXT"))
                        #expect(plist.dictValue?["CFBundleSupportedPlatforms"] == .plArray([.plString("DriverKit")]))
                    }
                }

                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyiOSDevice, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES"]), delegate: DriverKitBuildOperationDelegate()) { results in
                    results.checkNoDiagnostics()
                    results.checkNoFailedTasks()

                    try results.checkPropertyListContents(Path("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/App.app/Info.plist")) { plist in
                        #expect(plist.dictValue?["CFBundleSupportedPlatforms"] == .plArray([.plString("iPhoneOS")]))
                    }

                    try results.checkPropertyListContents(Path("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/App.app/SystemExtensions/Driver.dext/Info.plist")) { plist in
                        #expect(plist.dictValue?["CFBundlePackageType"] == .plString("DEXT"))
                        #expect(plist.dictValue?["CFBundleSupportedPlatforms"] == .plArray([.plString("DriverKit")]))
                    }
                }

                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyiOSSimulator, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES"]), delegate: DriverKitBuildOperationDelegate()) { results in
                    results.checkNoDiagnostics()
                    results.checkNoFailedTasks()

                    try results.checkPropertyListContents(Path("\(tmpDirPath.str)/Test/aProject/build/Debug-iphonesimulator/App.app/Info.plist")) { plist in
                        #expect(plist.dictValue?["CFBundleSupportedPlatforms"] == .plArray([.plString("iPhoneSimulator")]))
                    }

                    results.checkFileDoesNotExist(Path("\(tmpDirPath.str)/Test/aProject/build/Debug-iphonesimulator/App.app/SystemExtensions/Driver.dext"))

                    results.checkNote(.equal("Skipping '\(tmpDirPath.str)/Test/aProject/build/Debug-driverkit/Driver.dext' because DriverKit drivers are not supported in the iOS Simulator."))
                }
            }
        }
    }
}

final class DriverKitBuildOperationDelegate: SWBPlanningOperationDelegate {
    // Simulated implementation of the provisioning system which ad-hoc signs with the product type + project entitlements
    // FIXME: Find a way to call the real thing, perhaps in the future this is `xcsigningtool`
    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
        let signedEntitlements = provisioningSourceData.entitlementsDestination == "Signature"
        ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
        : [:]

        let simulatedEntitlements = provisioningSourceData.entitlementsDestination == "__entitlements"
        ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
        : [:]

        return SWBProvisioningTaskInputs(identityHash: "-", identityName: "-", profileName: nil, profileUUID: nil, profilePath: nil, designatedRequirements: nil, signedEntitlements: signedEntitlements.merging(provisioningSourceData.sdkRoot.contains("simulator") ? ["get-task-allow": .plBool(true)] : [:], uniquingKeysWith: { _, new  in new }), simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: nil, teamIdentifierPrefix: nil, isEnterpriseTeam: false, keychainPath: nil, errors: [], warnings: [])
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
        .deferred
    }
}
