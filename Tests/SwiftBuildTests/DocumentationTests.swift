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
fileprivate struct DocumentationBuildTests: CoreBasedTests {
    // docc fails on Windows for some reason
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory, .skipHostOS(.windows))
    func documentationBuild() async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs: any FSProxy = localFS

            let testProject = TestProject(
                "docProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("test.docc"),
                        TestFile("test.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                        "SWIFT_VERSION": "5.0",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Foo",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "test.docc",
                                "test.swift",
                            ])
                        ]),
                ])

            let SRCROOT = tmpDir.str

            try fs.write(Path(SRCROOT).join("test.swift"), contents: "")
            try fs.createDirectory(Path(SRCROOT).join("test.docc"))
            try fs.write(Path(SRCROOT).join("test.docc").join("test.md"), contents:
                """
                # Article

                A top-level article in a documentation catalog without any symbols

                @Metadata {
                  @TechnologyRoot
                }
                """
            )

            try await withTester(testProject, fs: fs) { tester in
                let runDestination = SWBRunDestinationInfo.host
                try await tester.checkBuild(SWBBuildParameters(action: SWBBuildAction.docBuild.rawValue, configuration: "Debug", activeRunDestination: runDestination)) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()
                    results.checkFileExists(tmpDir.join("build/Debug\(runDestination.builtProductsDirSuffix)/Foo.doccarchive"))
                }
            }
        }
    }
}
