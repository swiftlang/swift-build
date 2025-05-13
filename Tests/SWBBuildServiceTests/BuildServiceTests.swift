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
import SwiftBuild
import SWBBuildService
import SWBTestSupport
import SWBCore

@Suite fileprivate struct BuildServiceTests: CoreBasedTests {
    @Test func createXCFramework() async throws {
        do {
            let (result, message) = try await withBuildService { await $0.createXCFramework([], currentWorkingDirectory: Path.root.str, developerPath: nil) }
            #expect(!result)
            #expect(message == "error: at least one framework or library must be specified.\n")
        }

        do {
            let (result, message) = try await withBuildService { await $0.createXCFramework(["createXCFramework"], currentWorkingDirectory: Path.root.str, developerPath: nil) }
            #expect(!result)
            #expect(message == "error: at least one framework or library must be specified.\n")
        }

        do {
            let (result, message) = try await withBuildService { await $0.createXCFramework(["createXCFramework", "-help"], currentWorkingDirectory: Path.root.str, developerPath: nil) }
            #expect(result)
            #expect(message.starts(with: "OVERVIEW: Utility for packaging multiple build configurations of a given library or framework into a single xcframework."))
        }
    }

    @Test func macCatalystSupportsProductTypes() async throws {
        #expect(try await withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.product-type.application") })
        #expect(try await withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.product-type.framework") })
        #expect(try await !withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.product-type.application.on-demand-install-capable") })

        // False on non-existent product types
        #expect(try await !withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "doesnotexist") })

        // Error on spec identifiers which aren't product types
        await #expect(throws: (any Error).self) {
            try await withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.package-type.wrapper") }
        }
    }

    @Test func testGenerateRunnableInfo_Success() async throws {
        let core = await getCore()
        let fs = core.fsProvider.createFileSystem()

        let workspaceName = "RunnableTestWorkspace"
        let projectName = "MyProject"
        let targetName = "MyExecutable"
        let testWorkspace = try TestWorkspace(
            workspaceName,
            projects: [
                TestProject(
                    projectName,
                    targets: [
                        TestStandardTarget(targetName, type: .commandLineTool)
                    ])
            ])

        let loadedWorkspace = testWorkspace.load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: loadedWorkspace, fs: fs, processExecutionCache: .sharedForTesting)

        let session = Session(core, "TestSession", cachePath: nil)
        session.workspaceContext = workspaceContext

        let target = try #require(loadedWorkspace.findTarget(name: targetName, project: projectName))
        var buildParameters = SWBBuildParameters()
        buildParameters.configurationName = "Debug" 

        var request = SWBBuildRequest()
        request.parameters = buildParameters
        let targetID = target.guid

        let delegate = TestPlanningOperationDelegate()

        let runnableInfo = try await session.generateRunnableInfo(for: request, targetID: targetID, delegate: delegate)

        let coreParams = try BuildParameters(from: request.parameters)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let settings = Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: coreParams, project: workspaceContext.workspace.project(for: target), target: target)
        let scope = settings.globalScope
        let buildDir = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
        let execPath = scope.evaluate(BuiltinMacros.EXECUTABLE_PATH)
        let expectedPath = try AbsolutePath(validating: buildDir.join(Path(execPath)).str)

        #expect(runnableInfo.executablePath == expectedPath)
    }

    @Test func testGenerateRunnableInfo_TargetNotFound() async throws {
        let core = await getCore()
        let fs = core.fsProvider.createFileSystem()

        let testWorkspace = try TestWorkspace("NotFoundWorkspace", projects: [TestProject("DummyProject")])
        let loadedWorkspace = testWorkspace.load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: loadedWorkspace, fs: fs, processExecutionCache: .sharedForTesting)

        let session = Session(core, "TestSessionNotFound", cachePath: nil)
        session.workspaceContext = workspaceContext

        let nonExistentTargetID = "non-existent-guid"
        var request = SWBBuildRequest()
        request.parameters.configurationName = "Debug"

        let delegate = TestPlanningOperationDelegate()

        await #expect(throws: Session.TargetNotFoundError.self) {
            _ = try await session.generateRunnableInfo(for: request, targetID: nonExistentTargetID, delegate: delegate)
        }
    }

    @Test func testGenerateRunnableInfo_TargetNotRunnable() async throws {
        let core = await getCore()
        let fs = core.fsProvider.createFileSystem()

        let workspaceName = "NotRunnableWorkspace"
        let projectName = "LibProject"
        let targetName = "MyStaticLib"
        let testWorkspace = try TestWorkspace(
            workspaceName,
            projects: [
                TestProject(
                    projectName,
                    targets: [
                        TestStandardTarget(targetName, type: .staticLibrary)
                    ])
            ])

        let loadedWorkspace = testWorkspace.load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: loadedWorkspace, fs: fs, processExecutionCache: .sharedForTesting)

        let session = Session(core, "TestSessionNotRunnable", cachePath: nil)
        session.workspaceContext = workspaceContext

        let target = try #require(loadedWorkspace.findTarget(name: targetName, project: projectName))
        var request = SWBBuildRequest()
        request.parameters.configurationName = "Debug"
        let targetID = target.guid

        let delegate = TestPlanningOperationDelegate()

        await #expect(throws: Session.TargetNotRunnableError.self) {
            _ = try await session.generateRunnableInfo(for: request, targetID: targetID, delegate: delegate)
        }
    }
}

extension CoreBasedTests {
    func withBuildService<T>(_ block: (SWBBuildService) async throws -> T) async throws -> T {
        try await withAsyncDeferrable { deferrable in
            let service = try await SWBBuildService()
            await deferrable.addBlock {
                await service.close()
            }
            return try await block(service)
        }
    }
}
