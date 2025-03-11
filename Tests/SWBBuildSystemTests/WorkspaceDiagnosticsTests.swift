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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct WorkspaceDiagnosticsTests: CoreBasedTests {
    // MARK: - Unavailable target type checks

    @Test(.requireSDKs(.macOS))
    func appClipWorkspaceDiagnostic() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("Source.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "INFOPLIST_FILE": "Info.plist",
                        "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Foo",
                        type: .appClip,
                        buildPhases: [
                            TestSourcesBuildPhase(["Source.m"]),
                        ]),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)

            try await tester.checkBuildDescription(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
                results.checkError(.equal("[targetIntegrity] App Clips are not available when building for Mac Catalyst. (in target 'Foo' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }
    }
}
