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
import SWBUtil
import SWBProtocol

@Suite(.performance)
fileprivate struct ModulesVerifierPerfTests: CoreBasedTests, PerfTests {
    @Test(.requireSDKs(.macOS), arguments: [true, false])
    func modulesVerifierPerf(verify: Bool) async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("VerifyModulePerfTest")
            let testProject = TestProject("MyProject",
                                          sourceRoot: srcRoot,
                                          groupTree: TestGroup("SomeFiles", path: "", children: [
                                            TestFile("MyFramework.h"),
                                            TestFile("MyFramework_Private.h"),
                                            TestFile("PublicHeader.h"),
                                            TestFile("PrivateHeader.h"),
                                            TestFile("SourceFile.m"),
                                          ]),
                                          buildConfigurations: [
                                            TestBuildConfiguration("Debug", buildSettings: [
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "DEFINES_MODULE": "YES",
                                                "MODULEMAP_FILE": "public.modulemap",
                                                "MODULEMAP_PRIVATE_FILE": "private.modulemap",
                                                "INSTALL_OWNER": "",
                                                "INSTALL_GROUP": "staff",
                                            ])
                                          ],
                                          targets: [
                                            TestStandardTarget("MyFramework", type: .framework, buildPhases: [
                                                TestHeadersBuildPhase([
                                                    TestBuildFile("MyFramework.h", headerVisibility: .public),
                                                    TestBuildFile("MyFramework_Private.h", headerVisibility: .private),
                                                    TestBuildFile("PublicHeader.h", headerVisibility: .public),
                                                    TestBuildFile("PrivateHeader.h", headerVisibility: .private),
                                                ]),
                                                TestSourcesBuildPhase([
                                                    "SourceFile.m"
                                                ])
                                            ])
                                          ]
            )

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            try await tester.fs.writeFileContents(srcRoot.join("MyFramework.h")) { stream in
                stream <<< "#import <MyFramework/PublicHeader.h>\n"
            }
            try await tester.fs.writeFileContents(srcRoot.join("MyFramework_Private.h")) { stream in
                stream <<< "\n"
            }
            try await tester.fs.writeFileContents(srcRoot.join("PublicHeader.h")) { stream in
                stream <<< "void publicFunction(void);\n"
            }
            try await tester.fs.writeFileContents(srcRoot.join("PrivateHeader.h")) { stream in
                stream <<< "#import <MyFramework/PublicHeader.h>\n"
                stream <<< "void privateFunction(void);\n"
            }
            try await tester.fs.writeFileContents(srcRoot.join("SourceFile.m")) { stream in
                stream <<< "#import \"PrivateHeader.h\"\n"
                stream <<< "void publicFunction(void) {}\n"
                stream <<< "void privateFunction(void) {}\n"
            }
            try await tester.fs.writeFileContents(srcRoot.join("public.modulemap")) { stream in
                stream <<< "framework module MyFramework {\n"
                stream <<< "  umbrella header \"MyFramework.h\"\n"
                stream <<< "  export *\n"
                stream <<< "  module * { export * }\n"
                stream <<< "}\n"
            }
            try await tester.fs.writeFileContents(srcRoot.join("private.modulemap")) { stream in
                stream <<< "framework module MyFramework_Private {\n"
                stream <<< "  exclude header \"MyFramework_Private.h\""
                stream <<< "  explicit module PrivateHeader {\n"
                stream <<< "    header \"PrivateHeader.h\"\n"
                stream <<< "    export *\n"
                stream <<< "  }\n"
                stream <<< "}\n"
            }

            let params = BuildParameters(action: .build, configuration: "Debug", overrides: [
                "ENABLE_MODULE_VERIFIER": verify ? "YES" : "NO",
            ])

            try await tester.checkBuild(parameters: params, runDestination: .macOS, serial: true) { results in
            }

            let filesToTouch = [srcRoot.join("PublicHeader.h"), srcRoot.join("PrivateHeader.h")]

            try await measure {
                for _ in 0..<5 { // loop enough to make the measured time longer, and the standard deviation relatively low
                    for file in filesToTouch {
                        try tester.fs.touch(file)
                    }
                    try await tester.checkBuild(parameters: params, runDestination: .macOS, serial: true) { results in
                    }
                }
            }
        }
    }
}
