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
fileprivate struct WatchTests: CoreBasedTests {
    @Test(.requireSDKs(.watchOS))
    func extensionlessWatchApp() async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs: any FSProxy = localFS

            let testProject = TestProject(
                "App",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("main.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "watchos",
                        "SWIFT_VERSION": "5.0",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"])
                        ]),
                ])

            let SRCROOT = tmpDir.str

            try fs.createDirectory(Path(SRCROOT))
            try fs.write(Path(SRCROOT).join("main.swift"), contents: "")

            try await withTester(testProject, fs: fs) { tester in
                try await tester.checkBuild(SWBBuildParameters(action: SWBBuildAction.build.rawValue, configuration: "Debug", activeRunDestination: .anywatchOSDevice)) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()

                    try results.checkPropertyListContents(tmpDir.join("build/Debug-watchos/App.app/Info.plist")) { plist in
                        #expect(plist.dictValue?["MinimumOSVersion~ipad"]?.stringValue == "9.0")
                        #expect(plist.dictValue?["WKApplication"]?.boolValue == true)
                        #expect(plist.dictValue?["WKWatchKitApp"] == nil)
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.watchOS))
    func extensionBasedWatchApp() async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs: any FSProxy = localFS

            let testProject = TestProject(
                "App",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("main.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "watchos",
                        "SWIFT_VERSION": "5.0",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .watchKitApp,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        buildPhases: [
                        ]),
                ])

            let SRCROOT = tmpDir.str

            try fs.createDirectory(Path(SRCROOT))

            try await withTester(testProject, fs: fs) { tester in
                try await tester.checkBuild(SWBBuildParameters(action: SWBBuildAction.build.rawValue, configuration: "Debug", activeRunDestination: .anywatchOSDevice)) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()

                    try results.checkPropertyListContents(tmpDir.join("build/Debug-watchos/App.app/Info.plist")) { plist in
                        #expect(plist.dictValue?["WKWatchKitApp"]?.boolValue == true)
                        #expect(plist.dictValue?["WKApplication"] == nil)
                        #expect(plist.dictValue?["MinimumOSVersion~ipad"] == nil)
                    }
                }

                try await tester.checkBuild(SWBBuildParameters(action: SWBBuildAction.build.rawValue, configuration: "Debug", activeRunDestination: .anywatchOSDevice, overrides: ["ENABLE_DEBUG_DYLIB": "YES"])) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()
                }
            }
        }
    }
}
