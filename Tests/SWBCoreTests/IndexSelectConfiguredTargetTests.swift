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
import Testing
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

@Suite fileprivate struct IndexSelectConfiguredTargetTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func selectConfiguredTarget() async throws {
        let core = try await getCore()

        let appTarget = TestStandardTarget(
            "appTarget",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx iphonesimulator iphoneos watchsimulator watchos",
                    "SUPPORTS_MACCATALYST": "YES",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ])

        let workspace = try await TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ])],
                    targets: [
                        appTarget
                    ])])

        let tester = try await BuildOperationTester(core, workspace, simulated: false)
        try await tester.checkIndexBuildGraph(targets: [appTarget]) { results in
            try results.checkSelectedPlatform(of: appTarget, "macos", "iphoneos", .macOS, expectedPlatform: "macos")
            try results.checkSelectedPlatform(of: appTarget, "iosmac", "macos", .macOS, expectedPlatform: "macos")
            try results.checkSelectedPlatform(of: appTarget, "macos", "iosmac", .watchOS, expectedPlatform: "macos")
            try results.checkSelectedPlatform(of: appTarget, "macos", "iosmac", .macCatalyst, expectedPlatform: "iosmac")
            try results.checkSelectedPlatform(of: appTarget, "iphonesimulator", "iosmac", .macOS, expectedPlatform: "iosmac")
            try results.checkSelectedPlatform(of: appTarget, "watchsimulator", "watchos", .macOS, expectedPlatform: "watchsimulator")
            try results.checkSelectedPlatform(of: appTarget, "watchsimulator", "macos", .iOSSimulator, expectedPlatform: "watchsimulator")
            try results.checkSelectedPlatform(of: appTarget, "iphoneos", "macos", .iOSSimulator, expectedPlatform: "iphoneos")
            try results.checkSelectedPlatform(of: appTarget, "iphonesimulator", "macos", .iOS, expectedPlatform: "iphonesimulator")
        }
    }
}
