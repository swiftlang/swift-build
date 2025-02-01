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

import SWBTestSupport
import Testing
import SwiftBuild
import SwiftBuildTestSupport

@Suite(.performance)
fileprivate struct BuildServicePerfTests: PerfTests {
    @Test
    func isAlivePerfX10() async throws {
        // Test the time to launch, ping, and shutdown the service.
        try await measure {
            // We do each iteration 10 times in order to samples that are more likely to be statistically significant.
            for _ in 0..<10 {
                let service = try await SWBBuildService()
                try await service.checkAlive()
                await service.close()
            }
        }
    }

    @Test
    func oneMessagePerfX10000() async throws {
        let service = try await SWBBuildService()

        // Ensure the service is up.
        try await service.checkAlive()

        try await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 0..<10000 {
                try await service.checkAlive()
            }
        }

        await service.close()
    }

    @Test
    func oneMessageAsyncPerfX10000() async throws {
        let service = try await SWBBuildService()

        // Ensure the service is up.
        let iterationCount = 10000
        try await service.checkAlive()

        try await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<iterationCount {
                    group.addTask {
                        try await service.checkAlive()
                    }
                }

                // Wait for the last reply.
                try await group.waitForAll()
            }
        }

        await service.close()
    }

    @Test
    func singleMacroEvaluationPerf_X1000() async throws {
        try await withAsyncDeferrable { deferrable in
            let service = try await SWBBuildService()
            await deferrable.addBlock {
                await service.close()
            }

            let (result, diagnostics) = await service.createSession(name: "test", cachePath: nil)
            #expect(diagnostics.isEmpty)
            let session = try result.get()
            await deferrable.addBlock {
                await #expect(throws: Never.self) {
                    try await session.close()
                }
            }

            // Send a mock PIF.
            //
            // FIXME: Move this to a file, or something.
            let workspacePIF: SWBPropertyListItem = [
                "guid": "W1",
                "name": "aWorkspace",
                "path": "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
                "projects": ["P1"]
            ]
            let projectPIF: SWBPropertyListItem = [
                "guid": "P1",
                "path": "/tmp/aProject.xcodeproj",
                "groupTree": [
                    "guid": "G1",
                    "type": "group",
                    "name": "SomeFiles",
                    "sourceTree": "PROJECT_DIR",
                    "path": "/tmp/SomeProject/SomeFiles"
                ],
                "buildConfigurations": [
                    [
                        "guid": "BC1",
                        "name": "Config1",
                        "buildSettings": [
                            "USER_PROJECT_SETTING": "USER_PROJECT_VALUE"
                        ]
                    ]
                ],
                "targets": ["T1"],
                "defaultConfigurationName": "Config1",
                "developmentRegion": "English"
            ]
            let targetPIF: SWBPropertyListItem = [
                "guid": "T1",
                "name": "Target1",
                "type": "standard",
                "productTypeIdentifier": "com.apple.product-type.application",
                "productReference": [
                    "guid": "PR1",
                    "name": "MyApp.app"
                ],
                "buildPhases": [],
                "buildConfigurations": [
                    [
                        "guid": "C2",
                        "name": "Config1",
                        "buildSettings": [
                            "PRODUCT_NAME": "MyApp"
                        ]
                    ]
                ],
                "dependencies": [],
                "buildRules": []
            ]
            let topLevelPIF: SWBPropertyListItem = [
                [
                    "type": "workspace",
                    "signature": "W1",
                    "contents": workspacePIF
                ],
                [
                    "type": "project",
                    "signature": "P1",
                    "contents": projectPIF
                ],
                [
                    "type": "target",
                    "signature": "T1",
                    "contents": targetPIF
                ]
            ]

            try await session.sendPIF(topLevelPIF)

            // Create a build request and get a macro evaluation scope.
            var parameters = SWBBuildParameters()
            parameters.action = "build"
            parameters.configurationName = "Config1"

            // Measure evaluating the macro 100 times.
            try await measure {
                for _ in 0..<1000 {
                    let result = try await session.evaluateMacroAsString("PROJECT_NAME", level: .target("T1"), buildParameters: parameters, overrides: nil)
                    #expect(result == "aProject")
                }
            }
        }
    }

    // Throughput tests.

    @Test
    func throughput_1K_Message_X10000() async throws {
        try await withAsyncDeferrable { deferrable in
            let service = try await SWBBuildService()
            await deferrable.addBlock {
                await service.close()
            }

            try await service.checkAlive()

            // Allocate the payload.
            let N: Int = 1 << 10
            let payload = Array(Array(repeating: UInt8(ascii: "T"), count: N))

            try await measure {
                // We do each iteration many times in order to samples that are more likely to be statistically significant.
                for _ in 0..<10000 {
                    _ = try await service.sendThroughputTest(payload)
                }
            }
        }
    }

    @Test
    func throughput_1MB_Message_X100() async throws {
        try await withAsyncDeferrable { deferrable in
            let service = try await SWBBuildService()
            await deferrable.addBlock {
                await service.close()
            }

            try await service.checkAlive()

            // Allocate the payload.
            let N: Int = 1 << 20
            let payload = Array(Array(repeating: UInt8(ascii: "T"), count: N))

            try await measure {
                // We do each iteration many times in order to samples that are more likely to be statistically significant.
                for _ in 0..<100 {
                    _ = try await service.sendThroughputTest(payload)
                }
            }
        }
    }
}
