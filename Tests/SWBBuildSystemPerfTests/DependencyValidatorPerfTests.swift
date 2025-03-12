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
import SWBTestSupport
import SWBTaskExecution
import SWBUtil

@Suite(.performance)
fileprivate struct DependencyValidatorPerfTests: CoreBasedTests, PerfTests {
    @Test(.requireSDKs(.macOS), arguments: [true, false])
    func dependencyValidatorBuildOperationPerf(on: Bool) async throws {
        try await withTemporaryDirectory { tmp in
            let targets = (0..<10).map { i in
                TestStandardTarget("Target_\(i)",
                                   type: .framework,
                                   buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "CODE_SIGNING_ALLOWED": "NO",
                                        "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SWIFT_VERSION": "5",
                                        "SWIFT_COMPILATION_MODE": "wholemodule",
                                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                                        "VALIDATE_DEPENDENCIES": on ? "YES" : "NO",
                                    ])
                                   ],
                                   buildPhases: [
                                    TestSourcesBuildPhase((0..<100).map { i in TestBuildFile("File\(i).swift") })
                                   ]
                )
            }

            let testWorkspace = TestWorkspace(
                "Workspace",
                sourceRoot: tmp,
                projects: [
                    TestProject("aProject",
                                groupTree: TestGroup("SomeFiles", children: [
                                ] + (0..<100).map { i in TestFile("File\(i).swift", sourceTree: .buildSetting("SRCROOT")) }),
                                targets: targets
                               )
                ])
            let core = try await getCore()

            try await measure {
                let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")
                for i in (0..<100) {
                    try await tester.fs.writeFileContents(SRCROOT.join("File\(i).swift")) { contents in
                        contents <<< "import Foundation\n"
                    }
                }

                let parameters = BuildParameters(action: .build, configuration: "Debug")
                let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.allTargets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }, dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                    results.checkTasks(.matchRuleItem("SwiftDriver")) { tasks in
                        #expect(tasks.count == targets.count)
                    }

                    results.checkTasks { tasks in
                        #expect(tasks.count > 0)
                    }

                    results.checkNoDiagnostics()
                }
            }
        }
    }
}
