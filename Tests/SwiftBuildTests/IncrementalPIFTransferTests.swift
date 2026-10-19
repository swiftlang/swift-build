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

import Foundation
import Testing
import SwiftBuild
import SwiftBuildTestSupport
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct IncrementalPIFTransferTests: CoreBasedTests {
    /// Transfers `workspace` incrementally, then sends the system and user info, as Xcode does.
    private func sendPIF(_ workspace: TestWorkspace, to testSession: TestSWBSession, systemInfo: SWBSystemInfo = .defaultForTesting, userInfo: SWBUserInfo = .defaultForTesting) async throws {
        var objects: [String: PropertyListItem] = [:]
        for object in try workspace.toObjects() {
            guard let signature = object.dictValue?["signature"]?.stringValue else {
                throw StubError.error("missing signature for PIF object")
            }
            objects[signature] = object
        }
        try await testSession.session.sendPIF(workspaceSignature: workspace.signature) { [objects] _, signature in
            guard let object = objects[signature] else {
                throw StubError.error("unexpected request for PIF object '\(signature)'")
            }
            return try .init(object)
        }
        try await testSession.session.setSystemInfo(systemInfo)
        try await testSession.session.setUserInfo(userInfo)
    }

    private func setUserPreferences(usePerConfigurationBuildLocations: Bool, in testSession: TestSWBSession) async throws {
        try await testSession.session.setUserPreferences(enableDebugActivityLogs: false, enableBuildDebugging: false, enableBuildSystemCaching: true, activityTextShorteningLevel: 0, usePerConfigurationBuildLocations: usePerConfigurationBuildLocations)
    }

    private func workspace(_ name: String, sourceRoot: Path) -> (TestWorkspace, TestStandardTarget) {
        let target = TestStandardTarget("\(name)Tool", type: .commandLineTool, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": name])])
        let workspace = TestWorkspace(name, sourceRoot: sourceRoot, projects: [
            TestProject(name, groupTree: TestGroup(name), buildConfigurations: [TestBuildConfiguration("Debug")], targets: [target])
        ])
        return (workspace, target)
    }

    private func evaluate(_ macro: String, for target: TestStandardTarget, in testSession: TestSWBSession) async throws -> String {
        try await testSession.session.evaluateMacroAsString(macro, level: .target(target.guid), buildParameters: SWBBuildParameters(configuration: "Debug"), overrides: nil)
    }

    private func withTestSession(_ body: (TestSWBSession, Path) async throws -> Void) async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }
                try await body(testSession, temporaryDirectory.path)
            }
        }
    }

    @Test
    func unchangedWorkspaceWithChangedUserInfo() async throws {
        try await withTestSession { testSession, sourceRoot in
            let (workspace, target) = workspace("Test", sourceRoot: sourceRoot)

            try await sendPIF(workspace, to: testSession, userInfo: .defaultForTesting.with(userName: "firstUser"))
            #expect(try await evaluate("USER", for: target, in: testSession) == "firstUser")

            try await sendPIF(workspace, to: testSession, userInfo: .defaultForTesting.with(userName: "firstUser"))
            #expect(try await evaluate("USER", for: target, in: testSession) == "firstUser")

            try await sendPIF(workspace, to: testSession, userInfo: .defaultForTesting.with(userName: "secondUser"))
            #expect(try await evaluate("USER", for: target, in: testSession) == "secondUser")
        }
    }

    @Test(.requireHostOS(.macOS))
    func unchangedWorkspaceWithChangedSystemInfo() async throws {
        try await withTestSession { testSession, sourceRoot in
            let (workspace, target) = workspace("Test", sourceRoot: sourceRoot)
            func systemInfo(_ productBuildVersion: String) -> SWBSystemInfo {
                SWBSystemInfo(operatingSystemVersion: SWBSystemInfo.defaultForTesting.operatingSystemVersion, productBuildVersion: productBuildVersion, nativeArchitecture: SWBSystemInfo.defaultForTesting.nativeArchitecture)
            }

            try await sendPIF(workspace, to: testSession, systemInfo: systemInfo("99A1"))
            #expect(try await evaluate("MAC_OS_X_PRODUCT_BUILD_VERSION", for: target, in: testSession) == "99A1")

            try await sendPIF(workspace, to: testSession, systemInfo: systemInfo("99A2"))
            #expect(try await evaluate("MAC_OS_X_PRODUCT_BUILD_VERSION", for: target, in: testSession) == "99A2")
        }
    }

    @Test
    func unchangedWorkspaceWithChangedUserPreferences() async throws {
        try await withTestSession { testSession, sourceRoot in
            let (workspace, target) = workspace("Test", sourceRoot: sourceRoot)
            func usesPerConfigurationBuildLocation() async throws -> Bool {
                try await evaluate("CONFIGURATION_BUILD_DIR", for: target, in: testSession) != evaluate("BUILD_DIR", for: target, in: testSession)
            }

            try await sendPIF(workspace, to: testSession)
            try await setUserPreferences(usePerConfigurationBuildLocations: false, in: testSession)
            #expect(try await usesPerConfigurationBuildLocation() == false)

            try await sendPIF(workspace, to: testSession)
            try await setUserPreferences(usePerConfigurationBuildLocations: true, in: testSession)
            #expect(try await usesPerConfigurationBuildLocation() == true)
        }
    }

    @Test
    func clearAllCachesReplacesWorkspaceContext() async throws {
        try await withTestSession { testSession, sourceRoot in
            let (workspace, target) = workspace("Test", sourceRoot: sourceRoot)
            func userInfo(_ value: String) -> SWBUserInfo {
                .defaultForTesting.with(buildSystemEnvironment: SWBUserInfo.defaultForTesting.buildSystemEnvironment.merging(["PIF_TRANSFER_TEST_VALUE": value], uniquingKeysWith: { $1 }))
            }

            try await sendPIF(workspace, to: testSession, userInfo: userInfo("first"))
            #expect(try await evaluate("PIF_TRANSFER_TEST_VALUE", for: target, in: testSession) == "first")

            try await testSession.session.setUserInfo(userInfo("second"))
            try await testSession.service.clearAllCaches()
            #expect(try await evaluate("PIF_TRANSFER_TEST_VALUE", for: target, in: testSession) == "second")
        }
    }

    @Test
    func changedWorkspace() async throws {
        try await withTestSession { testSession, sourceRoot in
            let (firstWorkspace, firstTarget) = workspace("First", sourceRoot: sourceRoot)
            let (secondWorkspace, secondTarget) = workspace("Second", sourceRoot: sourceRoot)

            try await sendPIF(firstWorkspace, to: testSession)
            #expect(try await evaluate("PRODUCT_NAME", for: firstTarget, in: testSession) == "First")

            try await sendPIF(secondWorkspace, to: testSession)
            #expect(try await evaluate("PRODUCT_NAME", for: secondTarget, in: testSession) == "Second")
            await #expect(throws: (any Error).self) {
                try await evaluate("PRODUCT_NAME", for: firstTarget, in: testSession)
            }
        }
    }
}
