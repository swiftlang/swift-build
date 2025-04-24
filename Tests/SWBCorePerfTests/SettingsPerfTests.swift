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
import SWBCore

import SWBTestSupport
import SWBProtocol

@Suite(.performance)
fileprivate struct SettingsPerfTests: CoreBasedTests, PerfTests {
    /// Measure the time to get the settings for a trivial native target.
    @Test
    func targetSettingsPerf_X100() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let helper = try await TestWorkspace(
                "Workspace",
                sourceRoot: tmpDirPath,
                projects: [
                    TestProject("aProject",
                                groupTree: TestGroup("SomeFiles"),
                                targets: [TestStandardTarget("Target1", type: .application)]
                               )
                ]).loadHelper(getCore())
            let context = helper.workspaceContext
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let project = helper.project
            let target = project.targets[0]
            let parameters = BuildParameters(action: .build, configuration: "Debug")

            // Measure the time to construct the settings for this target.
            await measure {
                for _ in 0..<100 {
                    let _ = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target, includeExports: false)
                }
            }
        }
    }
}
