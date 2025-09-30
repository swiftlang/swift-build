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
import Testing
import SwiftBuild
import SwiftBuildTestSupport
import SWBTestSupport
@_spi(Testing) import SWBUtil
import SWBProtocol
import SWBCore

@Suite
fileprivate struct BuildDescriptionLifecycleTests {
    @Test(.requireSDKs(.host))
    func configuredTargets() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let target = TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyLibrary.swift")])],
                )

                let project = TestProject(
                    "Test",
                    groupTree: TestGroup("Test", children: [TestFile("MyLibrary.swift")]),
                    targets: [target]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [project]))

                let activeRunDestination = SWBRunDestinationInfo.host
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParameters))

                var buildDescriptionID: SWBBuildDescriptionID?
                let buildDescriptionOperation = try await testSession.session.createBuildOperationForBuildDescriptionOnly(
                    request: request,
                    delegate: TestBuildOperationDelegate(),
                    retainBuildDescription: true
                )
                for try await event in try await buildDescriptionOperation.start() {
                    guard case .reportBuildDescription(let info) = event else {
                        continue
                    }
                    guard buildDescriptionID == nil else {
                        Issue.record("Received multiple build description IDs")
                        continue
                    }
                    buildDescriptionID = SWBBuildDescriptionID(info.buildDescriptionID)
                }
                guard let buildDescriptionID else {
                    throw StubError.error("Failed to get build description ID")
                }

                let targetInfos = try await testSession.session.configuredTargets(buildDescription: buildDescriptionID, buildRequest: request)
                #expect(targetInfos.count == 1)

                // Clear caches. The retained build description should remain available.
                try await testSession.service.clearAllCaches()
                let newTargetInfos = try await testSession.session.configuredTargets(buildDescription: buildDescriptionID, buildRequest: request)
                #expect(newTargetInfos.count == 1)

                await testSession.session.releaseBuildDescription(id: buildDescriptionID)
            }
        }
    }
}
