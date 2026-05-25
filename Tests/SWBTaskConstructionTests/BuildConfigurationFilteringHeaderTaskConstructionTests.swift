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

import Testing

import SWBCore
import SWBTestSupport
import SWBUtil
import struct SWBProtocol.BuildConfigurationFilter

@Suite
fileprivate struct BuildConfigurationFilteringHeaderTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func filteredPublicHeaderExcludedFromTAPIFileList() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("FwkFiltered.h"),
                    TestFile("Fwk.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_ENABLE_PROJECT_HEADERS": "YES",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO",
                ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_ENABLE_PROJECT_HEADERS": "YES",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public),
                            TestBuildFile("FwkFiltered.h", headerVisibility: .public, buildConfigurationFilters: BuildConfigurationFilter.releaseFilters),
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()
        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        // The expected TAPI file list under Debug contains only the unfiltered public header.
        // FwkFiltered.h is filtered to Release and must be excluded.
        let expectedHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/TEST/build/Debug/Fwk.framework/Headers/Fwk.h")
            ])
        ])

        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            // The filtered header must not have a CpHeader task.
            results.checkNoTask(.matchRuleType("CpHeader"), .matchRuleItemBasename("FwkFiltered.h"))

            // The unfiltered header must have a CpHeader task.
            results.checkTask(.matchRuleType("CpHeader"), .matchRuleItemBasename("Fwk.h")) { _ in }

            // The TAPI file list must omit the filtered header.
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Fwk.json")) { _, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["headers"] == expectedHeaders)
            }
        }
    }
}
