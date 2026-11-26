//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import class Foundation.ProcessInfo

import Testing

import SWBCore
import SWBTestSupport
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct GenericUnixStripTaskConstructionTests: CoreBasedTests {
    /// FreeBSD's strip doesn't support -D, so FreeBSD uses llvm-strip.
    @Test(.requireSDKs(.host), .requireHostOS(.linux, .freebsd, .openbsd))
    func stripToolForHostPlatform() async throws {
        let hostOS = try ProcessInfo.processInfo.hostOperatingSystem()
        let testProject = try TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", children: [TestFile("main.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": try hostOS.xcodePlatformName,
                    "STRIP_INSTALLED_PRODUCT": "YES",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "tool",
                    type: .commandLineTool,
                    buildConfigurations: [TestBuildConfiguration("Release")],
                    buildPhases: [TestSourcesBuildPhase(["main.c"])])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(configuration: "Release"), runDestination: .host) { results in
            results.checkNoErrors()
            results.checkTask(.matchRuleType("Strip")) { task in
                let strip = task.commandLine.first.map { Path($0.asString).basename }
                #expect(strip == (hostOS == .freebsd ? "llvm-strip" : "strip"))
                #expect(task.commandLine.contains("-D"))
            }
        }
    }
}
