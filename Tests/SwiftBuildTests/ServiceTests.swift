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

import class Foundation.Bundle
import struct Foundation.Data
import class Foundation.FileHandle
import class Foundation.FileManager
import class Foundation.ProcessInfo
import struct Foundation.URL

import SWBLibc
@_spi(Testing) import SwiftBuild
import class SWBCore.Core
import struct SWBCore.UserPreferences
import SWBProtocol
import Testing
import SWBTestSupport
import SwiftBuildTestSupport
@_spi(Testing) import SWBUtil

@Suite(.requireHostOS(.macOS))
fileprivate struct ServiceTests {
    @Test
    func closing() async throws {
        let service = try await SWBBuildService()

        // Verify we can contact the service.
        try await service.checkAlive()

        // Verify that closing the connection marks the service as having terminated.
        await service.close()
        #expect(service.terminated)

        // Verify we do not crash if attempting to re-use a closed connection.
        await #expect(throws: (any Error).self, performing: {
            try await service.checkAlive()
        })
    }

    // Regression test for rdar://84997640.
    @Test(.requireSDKs(.host))
    func sessionTeardown() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            try await withAsyncDeferrable { deferrable in
                let testTarget = TestStandardTarget(
                    "Target",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("foo.c"),
                        ])
                    ]
                )

                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Debug",
                    groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "USE_HEADERMAP": "YES",
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                            "DEFINES_MODULE": "YES",
                        ])
                    ],
                    targets: [testTarget])
                let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDir, projects: [testProject])

                try localFS.write(tmpDir.join("foo.c"), contents: "int main() { return 0; }")

                let service = try await SWBBuildService()
                do {
                    let (result, _) = await service.createSession(name: "S1", cachePath: nil)
                    let session = try result.get()
                    await deferrable.addBlock {
                        // At this point, the build has finished, so the cycle should have been broken and the session torn down.
                        do {
                            #expect(try await service.listSessions().count == 0)
                        } catch {
                            Issue.record(error)
                        }
                    }

                    await deferrable.addBlock {
                        await #expect(throws: Never.self) {
                            try await session.close()
                        }
                    }

                    #expect(try await service.listSessions().count == 1)

                    try await session.sendPIF(.init(testWorkspace.toObjects().propertyListItem))

                    var request = SWBBuildRequest()
                    try request.add(target: .init(guid: testWorkspace.findTarget(name: "Target", project: "aProject").guid, parameters: nil))

                    final class MockBuildOperationDelegate: SWBPlanningOperationDelegate {
                        func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
                            SWBProvisioningTaskInputs()
                        }

                        func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
                            .deferred
                        }
                    }

                    // Start the build. At this point, there will be a cycle from the SWBBuildService > SWBBuildServiceConnection > SWBBuildOperation > MockBuildOperationDelegate > SWBBuildService until the build completes and the channel is closed.
                    let delegate = MockBuildOperationDelegate()
                    let operation = try await session.createBuildOperation(request: request, delegate: delegate)
                    _ = try await operation.start()
                    await operation.waitForCompletion()
                }
            }
        }
    }

    @Test
    func isAlive() async throws {
        let service = try await SWBBuildService()
        try await service.checkAlive()
    }

    /// Tests that all of the session API calls which rely on having a workspace context, throw such an error if we have not yet sent the PIF (as opposed to encountering a response timeout error).
    @Test
    func missingWorkspaceContext() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let session = testSession.session

                func assertErrorIsMissingWorkspaceContext(_ error: any Error) -> Bool {
                    error.localizedDescription.contains("missingWorkspaceContext")
                }

                await #expect(performing: {
                    try await session.createBuildOperation(request: SWBBuildRequest(), delegate: EmptyBuildOperationDelegate())
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.generateIndexingFileSettings(for: SWBBuildRequest(), targetID: "", delegate: EmptyBuildOperationDelegate())
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.generatePreviewInfo(for: SWBBuildRequest(), targetID: "", sourceFile: "", thunkVariantSuffix: "", delegate: EmptyBuildOperationDelegate())
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.generatePreviewTargetDependencyInfo(for: SWBBuildRequest(), targetIDs: [""], delegate: EmptyBuildOperationDelegate())
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.describeArchivableProducts(input: [])
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.describeSchemes(input: [])
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.describeProducts(input: .init(configurationName: "Debug", targetIdentifiers: []), platformName: "macosx")
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.setSystemInfo(.defaultForTesting)
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })

                await #expect(performing: {
                    try await session.setUserInfo(.defaultForTesting)
                }, throws: {
                    assertErrorIsMissingWorkspaceContext($0)
                })
            }
        }
    }

    /// Test the spec dumping command.
    @Test
    func showSpecs() async throws {
        try await withAsyncDeferrable { deferrable in
            let service = try await SWBBuildService()
            await deferrable.addBlock {
                await service.close()
            }

            let (result, _) = await service.createSession(name: "FOO", developerPath: nil, cachePath: nil, inferiorProductsPath: nil, environment: nil)
            let createdSession = try result.get()
            await deferrable.addBlock {
                await #expect(throws: Never.self) {
                    try await createdSession.close()
                }
            }

            let output = await createdSession.getSpecsDump(commandLine: []).output
            XCTAssertMatch(output, .contains("Name: com.apple.xcode.tools.swift.compiler"))
        }
    }

    /// Test sending a single large (10K) message.
    @Test
    func largeMessages() async throws {
        let service = try await SWBBuildService()
        try await service.checkAlive()

        let N: size_t = 10 * 1024
        let message = Array(repeating: UInt8(0), count: N)
        #expect(try await service.sendThroughputTest(message))
    }

    @Test(.requireSDKs(.macOS), .skipSwiftPackage, .skipIfEnvironment(key: "DYLD_IMAGE_SUFFIX", value: "_asan"), .disabled(if: getEnvironmentVariable("CI")?.isEmpty == false))
    func ASanBuildService() async throws {
        let testBundleExecutableFilePath = Library.locate(Self.self)

        // Whether the current XCTest executable is running in ASan mode. Most likely never true.
        let runningWithASanSupport = testBundleExecutableFilePath.str.hasSuffix("_asan")

        // Whether the current XCTest bundle has an _asan executable variant (but that variant is not necessarily the currently executing variant).
        let builtWithASanSupport = runningWithASanSupport || FileManager.default.isExecutableFile(atPath: testBundleExecutableFilePath.str + "_asan")

        let launchURL = try SWBBuildServiceConnection.effectiveLaunchURL(for: .default, serviceBundleURL: nil, environment: [:])
        let executableName = launchURL.0.lastPathComponent

        try await withTemporaryDirectory { temporaryDirectory in
            let tmpDir = temporaryDirectory.path
            let testProject = TestProject(
                "aProject",
                defaultConfigurationName: "Debug",
                groupTree: TestGroup("Foo", children: [TestFile("tool.c"), TestFile("foo.intentdefinition")]),
                targets: [])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDir, projects: [testProject])

            func testVariant(variant: SWBBuildServiceVariant, _ expectedExecutableFileName: String, file: StaticString = #filePath, line: UInt = #line) async throws {
                try await withAsyncDeferrable { deferrable in
                    // Construct the test session.
                    let testSession = try await TestSWBSession(connectionMode: .outOfProcess, variant: variant, temporaryDirectory: temporaryDirectory)
                    await deferrable.addBlock {
                        await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                    }

                    let tester = try await CoreQualificationTester(testWorkspace, testSession)
                    let session = testSession.session
                    try await session.setUserPreferences(UserPreferences.defaultForTesting.with(enableDebugActivityLogs: true))

                    let events = try await testSession.runBuildOperation(request: SWBBuildRequest(), delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events) { results in
                        results.checkNote(.and(.and(.prefix("Using build service at: "), .contains("Contents/MacOS/\(expectedExecutableFileName)")), .not(.contains("DYLD_IMAGE_SUFFIX=_asan"))))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }
                }
            }

            // The default is to launch the _asan service if the currently executing image is an _asan one
            try await testVariant(
                variant: .default,
                runningWithASanSupport ? "\(executableName)_asan" : executableName)

            // An explicit request for normal always uses normal
            try await testVariant(
                variant: .normal,
                executableName)

            // An explicit request for ASan launches the ASan service if it exists, otherwise uses normal
            try await testVariant(
                variant: .asan,
                builtWithASanSupport ? "\(executableName)_asan" : executableName)
        }
    }

    /// Tests an obscure edge case where a project configured in a specific way can trigger a condition such that the build operation's "target preparation" can be requested multiple times. If the target fails scanning due to a missing input, but also emits diagnostics early in its build process such that they'll be handled by the deferred diagnostics mechanism, we may call the `targetPreparationStarted` callback multiple times. Ensure that we check if we've done do to avoid triggering the assertion in debug mode, and inserting a duplicate ID mapping for the configured target.
    @Test(.requireSDKs(.host))
    func deferredTargetDiagnosticsWithDuplicateTargetPreparation() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                // We need at least two targets with inputs which don't exist so scanning will fail
                let testTarget = TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("tool.c"),
                        ])
                    ],
                    dependencies: ["Tool2"]
                )

                let testTarget2 = TestStandardTarget(
                    "Tool2",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("tool.c"),
                        ])
                    ]
                )

                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Debug",
                    groupTree: TestGroup("Foo", children: [TestFile("tool.c")]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",

                            // We need a setting that'll cause a diagnostic to get emitted quite early,
                            // but not one that's an error and stops the build
                            "DEVELOPMENT_ASSET_PATHS": "bogus",
                            "VALIDATE_DEVELOPMENT_ASSET_PATHS": "YES",

                        ])
                    ],
                    targets: [testTarget, testTarget2])
                let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDir, projects: [testProject])

                // Construct the test session.
                let testSession = try await TestSWBSession(connectionMode: .outOfProcess, temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let tester = try await CoreQualificationTester(testWorkspace, testSession)

                var request = SWBBuildRequest()
                request.continueBuildingAfterErrors = true
                try request.add(target: .init(guid: testWorkspace.findTarget(name: "Tool", project: "aProject").guid, parameters: nil))

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                #expect(!testSession.session.terminated)

                try await tester.checkResults(events: events) { results in
                    for _ in 0..<4 {
                        results.checkError(.equal("Build input file cannot be found: '\(tmpDir.str)/aProject/tool.c'. Did you forget to declare this file as an output of a script phase or custom build rule which produces it?"))
                    }

                    for _ in 0..<2 {
                        results.checkWarning(.equal("One of the paths in DEVELOPMENT_ASSET_PATHS does not exist: \(tmpDir.str)/aProject/bogus"))
                    }

                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test
    func developerDir() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(connectionMode: .outOfProcess, temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let developerPath = try await testSession.session.developerPath()
                #expect(developerPath.hasSuffix("/Contents/Developer"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func deploymentTargetValidation() async throws {
        try await withTemporaryDirectory { path in
            try localFS.write(path.join("main.c"), contents: "int main() { return 0; }")
            let osv = ProcessInfo.processInfo.operatingSystemVersion
            let osVersion = try Version(osv)
            let deploymentTarget = Version(Version.Component(osv.majorVersion), Version.Component(osv.minorVersion), UInt(osv.patchVersion) + 1)
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang", "-target", "\(#require(Architecture.host.stringValue))-apple-macos\(deploymentTarget.canonicalDeploymentTargetForm)", "main.c"], workingDirectory: path.str)

            _ = await withEnvironment(["SWBBUILDSERVICE_PATH": path.join("a.out").str]) {
                await #expect(performing: {
                    try await SWBBuildService(connectionMode: .outOfProcess)
                }, throws: { error in
                    String(describing: error) == "Couldn't launch the build service process '\(path.str)/a.out' because it requires macOS \(deploymentTarget.canonicalDeploymentTargetForm) or later (running macOS \(osVersion.canonicalDeploymentTargetForm))."
                })
            }
        }
    }

    @Test
    func sessionCrashRecovery() async throws {
        let service = try await SWBBuildService(connectionMode: .outOfProcess)
        try await service.checkAlive()

        // Create a session, which references the service.
        let (sessionResult, diagnostics) = await service.createSession(name: "Test", cachePath: nil)
        #expect(diagnostics.filter { $0.kind == .error}.isEmpty)
        let session = try sessionResult.get()

        // Send a simple session message, which should succeed.
        _ = try await session.developerPath()

        // Crash the service. The client side SWBBuildService object will remain valid, but the backing server side will be renewed after the process relaunch.
        await service.terminate()
        #expect(service.terminated)

        // Send a simple message, which should now fail due to the underlying service termination.
        await #expect(performing: {
            try await session.developerPath()
        }, throws: { error in
            (error as? SwiftBuildError) == .requestError(description: "The Xcode build system has crashed. Build again to continue.")
        })

        // Restart the service.
        try await service.restart()

        // Send a simple message again, which should fail because the session is no longer valid.
        await #expect(performing: {
            try await session.developerPath()
        }, throws: { error in
            (error as? SwiftBuildError) == .requestError(description: "unknownSession(handle: \"S0\")")
        })

        // The service has already been restart, so it should not be marked terminated.
        #expect(!service.terminated)

        // But the session is no longer valid due to the restart, so it SHOULD be marked terminated.
        // It is now the client's responsibility to renew the session.
        #expect(session.terminated)

        // Closing will also fail because the session is no longer valid, but we need to attempt closing or we'll assert.
        await #expect(performing: {
            try await session.close()
        }, throws: { error in
            (error as? SwiftBuildError) == .requestError(description: "unknownSession(handle: \"S0\")")
        })
    }
}
