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
import SWBTestSupport
@_spi(Testing) import SWBUtil

import SWBTaskExecution
import SWBProtocol

@Suite
fileprivate struct DependencyVerificationBuildOperationTests: CoreBasedTests {

    @Test(.requireSDKs(.macOS))
    func actualMinimalFramework() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources",
                            children: [
                                TestFile("CoreFoo.m")
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_MODULES": "NO",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "DEPENDENCIES": "Foundation UIKit",
                                    // Disable the SetOwnerAndGroup action by setting them to empty values.
                                    "INSTALL_GROUP": "",
                                    "INSTALL_OWNER": "",
                                ]
                            )
                        ],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m"])
                                ])
                        ])
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/CoreFoo.m")) { contents in
                contents <<< """
                        #include <Foundation/Foundation.h>
                        #include <Accelerate/Accelerate.h>

                        void f0(void) { };
                    """
            }

            let parameters = BuildParameters(
                action: .install, configuration: "Debug",
                overrides: [
                    "DSTROOT": tmpDirPath.join("dst").str
                ])

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                results.checkError(.contains("Undeclared dependencies: \n  Accelerate"))
            }
        }
    }
}
