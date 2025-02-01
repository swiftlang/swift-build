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

@Suite(.requireHostOS(.macOS))
fileprivate struct ProvisioningTaskInputsTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func entitlementsViaBuildSetting() async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs: any FSProxy = localFS

            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("main.m"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ONLY_ACTIVE_ARCH": "YES",
                        "SDKROOT": "macosx",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.entitlements",
                        "CODE_SIGN_ENTITLEMENTS_CONTENTS": ByteString(try PropertyListItem.plDict(["com.apple.entitlement-from-build-setting": true]).asBytes(.xml)).asString,
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.apple.App",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "main.m",
                            ])
                        ]
                    ),
                ]
            )

            let SRCROOT = tmpDir.str
            try fs.write(Path(SRCROOT).join("main.m"), contents: "int main(int argc, const char **argv) { return 0; }")
            try await fs.writePlist(Path(SRCROOT).join("Entitlements.entitlements"), .plDict(["com.apple.entitlement-from-file": true]))

            try await confirmation("Provisioning task inputs requested") { provisioningTaskInputsExpectation in
                final class MockBuildOperationDelegate: SWBPlanningOperationDelegate {
                    let provisioningTaskInputsExpectation: Confirmation
                    private let delegate = TestBuildOperationDelegate()

                    init(provisioningTaskInputsExpectation: Confirmation) {
                        self.provisioningTaskInputsExpectation = provisioningTaskInputsExpectation
                    }

                    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
                        provisioningTaskInputsExpectation.confirm()

                        // The default implementation of this is sufficient for our needs, so delegate back to it.
                        return await delegate.provisioningTaskInputs(targetGUID: targetGUID, provisioningSourceData: provisioningSourceData)
                    }

                    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
                        return try await delegate.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                    }
                }

                try await withTester(testProject, fs: fs) { tester in
                    try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .macOS), delegate: MockBuildOperationDelegate(provisioningTaskInputsExpectation: provisioningTaskInputsExpectation)) { results in
                        results.checkNoFailedTasks()
                        results.checkNoDiagnostics()

                        try await results.checkEntitlements(.signed, Path(SRCROOT).join("build/Debug/App.app/Contents/MacOS/App")) { plist in
                            #expect(plist == [
                                "application-identifier": "com.apple.App",
                                "com.apple.entitlement-from-build-setting": true,
                                "com.apple.entitlement-from-file": true,
                            ])
                        }
                    }
                }
            }
        }
    }
}
