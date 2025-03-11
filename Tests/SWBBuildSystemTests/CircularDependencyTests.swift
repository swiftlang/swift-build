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

import SWBUtil
import SWBBuildSystem
import SWBCore
import SWBTestSupport

@Suite
fileprivate struct CircularDependencyTests: CoreBasedTests {
    /// Tests a higher level framework which links a lower level framework, where the lower level framework depends on the higher level framework's headers.
    @Test(.requireSDKs(.iOS), .flaky("Occasionally fails in CI due to tasks in HighLevel starting even though it has a hard dependency edge on LowLevel due to target build order"), .bug("rdar://137903531"))
    func circularLayeringViolationDependency() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("HighLevel.h"),
                            TestFile("HighLevel.m"),
                            TestFile("LowLevel.h"),
                            TestFile("LowLevel.m"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                                "SDKROOT": "iphoneos",
                                "DEFINES_MODULE": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "HighLevel",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("HighLevel.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase([TestBuildFile("HighLevel.m")]),
                                ]
                            ),
                            TestStandardTarget(
                                "LowLevel",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("LowLevel.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase([TestBuildFile("LowLevel.m")]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/HighLevel.h")) {
                $0.write("#import <Foundation/Foundation.h>")
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/LowLevel.h")) {
                $0.write("#import <Foundation/Foundation.h>")
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/HighLevel.m")) {
                $0.write("")
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/LowLevel.m")) {
                $0.write("#include <HighLevel/HighLevel.h>")
            }

            let buildParameters = BuildParameters(configuration: "Debug")

            try await tester.checkBuild(parameters: buildParameters, runDestination: .iOS, buildRequest: BuildRequest(parameters: buildParameters, buildTargets: [
                .init(parameters: buildParameters, target: tester.workspace.projects[0].targets[1]),
                .init(parameters: buildParameters, target: tester.workspace.projects[0].targets[0])
            ], dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)) { results in
                results.checkError(.prefix("Command CompileC failed."))
                results.checkError(.prefix("\(tmpDirPath.str)/Test/aProject/LowLevel.m:1:10: [Lexical or Preprocessor Issue] \'HighLevel/HighLevel.h\' file not found"))
                results.checkNoDiagnostics()

                // We should not have started any tasks in HighLevel because of target build order, HighLevel must wait until LowLevel is done
                results.checkTasks(.matchTargetName("HighLevel")) { tasks in
                    #expect(tasks.count == 0)
                }

                #expect(results.buildTranscript.contains("'HighLevel/HighLevel.h' file not found"))

                var paths: [Path] = []
                try tester.fs.traverse(tmpDirPath.join("Test/aProject/build/Debug-iphoneos")) { paths.append($0) }
                paths.sort()

                #expect(paths == [
                    tmpDirPath.join("Test/aProject/build/Debug-iphoneos/LowLevel.framework"),
                    tmpDirPath.join("Test/aProject/build/Debug-iphoneos/LowLevel.framework/Headers"),
                    tmpDirPath.join("Test/aProject/build/Debug-iphoneos/LowLevel.framework/Headers/LowLevel.h"),
                ])
            }
        }
    }
}
