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

// These tests use the old model, ie. the index build arena is disabled.
@Suite(.requireHostOS(.macOS))
fileprivate struct InspectBuildDescriptionTests {
    @Test(.requireSDKs(.macOS))
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

                let frameworkTarget = TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyFramework.swift")])],
                )

                let appTarget = TestStandardTarget(
                    "MyApp",
                    type: .application,
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyApp.swift")])],
                    dependencies: [TestTargetDependency("MyFramework")]
                )

                let project = TestProject(
                    "Test",
                    groupTree: TestGroup("Test", children: [TestFile("MyFramework.swift"), TestFile("MyApp.swift")]),
                    targets: [frameworkTarget, appTarget]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [project]))

                let activeRunDestination = SWBRunDestinationInfo.macOS
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: buildParameters))

                let buildDescriptionID = try await testSession.session.createBuildDescription(buildRequest: request)
                let targetInfos = try await testSession.session.configuredTargets(buildDescription: buildDescriptionID, buildRequest: request)

                #expect(Set(targetInfos.map(\.name)) == ["MyFramework", "MyApp"])
                let frameworkTargetInfo = try #require(targetInfos.filter { $0.name == "MyFramework" }.only)
                #expect(frameworkTargetInfo.dependencies == [])
                #expect(frameworkTargetInfo.toolchain != nil)
                let appTargetInfo = try #require(targetInfos.filter { $0.name == "MyApp" }.only)
                #expect(appTargetInfo.dependencies == [frameworkTargetInfo.identifier])
                #expect(appTargetInfo.toolchain != nil)
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func artifacts() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let frameworkTarget = TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        .init("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)"
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("Foo.swift")])],
                )

                let staticLibraryTarget = TestStandardTarget(
                    "MyStaticLibrary",
                    type: .staticLibrary,
                    buildConfigurations: [
                        .init("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)"
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("Foo.swift")])],
                )

                let dynamicLibraryTarget = TestStandardTarget(
                    "MyDynamicLibrary",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        .init("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)"
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("Foo.swift")])],
                )

                let executableTarget = TestStandardTarget(
                    "MyExecutable",
                    type: .commandLineTool,
                    buildConfigurations: [
                        .init("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)"
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("Foo.swift")])],
                )

                let project = TestProject(
                    "Test",
                    groupTree: TestGroup("Test", children: [TestFile("Foo.swift")]),
                    targets: [frameworkTarget, staticLibraryTarget, dynamicLibraryTarget, executableTarget]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [project]))

                let activeRunDestination = SWBRunDestinationInfo.macOS
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: frameworkTarget.guid, parameters: buildParameters))
                request.add(target: SWBConfiguredTarget(guid: staticLibraryTarget.guid, parameters: buildParameters))
                request.add(target: SWBConfiguredTarget(guid: dynamicLibraryTarget.guid, parameters: buildParameters))
                request.add(target: SWBConfiguredTarget(guid: executableTarget.guid, parameters: buildParameters))

                let buildDescriptionID = try await testSession.session.createBuildDescription(buildRequest: request)
                let targetInfos = try await testSession.session.configuredTargets(buildDescription: buildDescriptionID, buildRequest: request)

                let frameworkTargetInfo = try #require(targetInfos.filter { $0.name == "MyFramework" }.only)
                #expect(frameworkTargetInfo.artifactInfo?.kind == .framework)
                #expect(frameworkTargetInfo.artifactInfo?.path.hasSuffix("MyFramework.framework") == true)

                let staticLibraryTargetInfo = try #require(targetInfos.filter { $0.name == "MyStaticLibrary" }.only)
                #expect(staticLibraryTargetInfo.artifactInfo?.kind == .staticLibrary)
                #expect(staticLibraryTargetInfo.artifactInfo?.path.hasSuffix("MyStaticLibrary.a") == true)

                let dynamicLibraryTargetInfo = try #require(targetInfos.filter { $0.name == "MyDynamicLibrary" }.only)
                #expect(dynamicLibraryTargetInfo.artifactInfo?.kind == .dynamicLibrary)
                #expect(dynamicLibraryTargetInfo.artifactInfo?.path.hasSuffix("MyDynamicLibrary.dylib") == true)

                let executableTargetInfo = try #require(targetInfos.filter { $0.name == "MyExecutable" }.only)
                #expect(executableTargetInfo.artifactInfo?.kind == .executable)
                #expect(executableTargetInfo.artifactInfo?.path.hasSuffix("MyExecutable") == true)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func configuredTargetSources() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let appTarget = TestStandardTarget(
                    "MyApp",
                    type: .application,
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyApp.swift")])]
                )

                let otherAppTarget = TestStandardTarget(
                    "MyOtherApp",
                    type: .application,
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyOtherApp.swift")])]
                )

                let project = TestProject(
                    "Test",
                    groupTree: TestGroup("Test", children: [TestFile("MyApp.swift"), TestFile("MyOtherApp.swift")]),
                    targets: [appTarget, otherAppTarget]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [project]))

                let activeRunDestination = SWBRunDestinationInfo.macOS
                var buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                buildParameters.overrides = SWBSettingsOverrides()
                buildParameters.overrides.commandLine = SWBSettingsTable()
                // Set `ONLY_ACTIVE_ARCH`, otherwise we get two entries for each Swift file, one for each architecture
                // with a different output path.
                buildParameters.overrides.commandLine!.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: buildParameters))
                request.add(target: SWBConfiguredTarget(guid: otherAppTarget.guid, parameters: buildParameters))

                let buildDescriptionID = try await testSession.session.createBuildDescription(buildRequest: request)
                let targetInfos = try await testSession.session.configuredTargets(buildDescription: buildDescriptionID, buildRequest: request)
                let appTargetInfo = try #require(targetInfos.filter { $0.name == "MyApp" }.only)
                let otherAppTargetInfo = try #require(targetInfos.filter { $0.name == "MyOtherApp" }.only)

                let appSources = try #require(await testSession.session.sources(of: [appTargetInfo.identifier], buildDescription: buildDescriptionID, buildRequest: request).only)
                #expect(appSources.configuredTarget == appTargetInfo.identifier)
                print(appSources.sourceFiles)
                let myAppFile = try #require(appSources.sourceFiles.only)
                #expect(myAppFile.path.pathString.hasSuffix("MyApp.swift"))
                #expect(myAppFile.language == .swift)
                #expect(myAppFile.indexOutputPath != nil)

                let combinedSources = try await testSession.session.sources(
                    of: [appTargetInfo.identifier, otherAppTargetInfo.identifier],
                    buildDescription: buildDescriptionID,
                    buildRequest: request
                )
                #expect(Set(combinedSources.map(\.configuredTarget)) == [appTargetInfo.identifier, otherAppTargetInfo.identifier])
                #expect(Set(combinedSources.flatMap(\.sourceFiles).map { URL(filePath: $0.path.pathString).lastPathComponent }) == ["MyApp.swift", "MyOtherApp.swift"])

                let emptyTargetListInfos = try await testSession.session.sources(of: [], buildDescription: buildDescriptionID, buildRequest: request)
                #expect(emptyTargetListInfos == [])

                await #expect(throws: (any Error).self) {
                    try await testSession.session.sources(
                        of: [SWBConfiguredTargetIdentifier(rawGUID: "does-not-exist", targetGUID: .init(rawValue: "does-not-exist"))],
                        buildDescription: buildDescriptionID,
                        buildRequest: request
                    )
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexCompilerArguments() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let appTarget = TestStandardTarget(
                    "MyApp",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MY_APP"])],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyApp.swift")])]
                )

                let otherAppTarget = TestStandardTarget(
                    "MyOtherApp",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MY_OTHER_APP"])],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyApp.swift")])]
                )

                let project = TestProject(
                    "Test",
                    groupTree: TestGroup("Test", children: [TestFile("MyApp.swift")]),
                    targets: [appTarget, otherAppTarget]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [project]))

                let activeRunDestination = SWBRunDestinationInfo.macOS
                var buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                buildParameters.overrides = SWBSettingsOverrides()
                buildParameters.overrides.commandLine = SWBSettingsTable()
                // Set `ONLY_ACTIVE_ARCH`, otherwise we get two entries for each Swift file, one for each architecture
                // with a different output path.
                buildParameters.overrides.commandLine!.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: buildParameters))
                request.add(target: SWBConfiguredTarget(guid: otherAppTarget.guid, parameters: buildParameters))

                let buildDescriptionID = try await testSession.session.createBuildDescription(buildRequest: request)
                let targetInfos = try await testSession.session.configuredTargets(buildDescription: buildDescriptionID, buildRequest: request)
                let appTargetInfo = try #require(targetInfos.filter { $0.name == "MyApp" }.only)
                let otherAppTargetInfo = try #require(targetInfos.filter { $0.name == "MyOtherApp" }.only)
                let appSources = try #require(await testSession.session.sources(of: [appTargetInfo.identifier], buildDescription: buildDescriptionID, buildRequest: request).only)
                let myAppFile = try #require(Set(appSources.sourceFiles.map(\.path)).filter { $0.pathString.hasSuffix("MyApp.swift") }.only)

                let appIndexSettings = try await testSession.session.indexCompilerArguments(of: myAppFile, in: appTargetInfo.identifier, buildDescription: buildDescriptionID, buildRequest: request)
                #expect(appIndexSettings.contains("-DMY_APP"))
                #expect(!appIndexSettings.contains("-DMY_OTHER_APP"))
                let otherAppIndexSettings = try await testSession.session.indexCompilerArguments(of: myAppFile, in: otherAppTargetInfo.identifier, buildDescription: buildDescriptionID, buildRequest: request)
                #expect(otherAppIndexSettings.contains("-DMY_OTHER_APP"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func selectConfiguredTargets() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let macOSAppTarget = TestStandardTarget(
                    "MyApp1",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx"])],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyApp1.swift")])]
                )

                let iOSAppTarget = TestStandardTarget(
                    "MyApp2",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "macosx iphoneos"])],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("MyApp2.swift")])],
                    dependencies: [TestTargetDependency("MyFramework")]
                )

                let project = TestProject(
                    "Test",
                    groupTree: TestGroup("Test", children: [TestFile("MyFramework.swift"), TestFile("MyApp1.swift"), TestFile("MyApp2.swift")]),
                    targets: [macOSAppTarget, iOSAppTarget]

                )

                let workspace = TestWorkspace("MyWorkspace", projects: [project])

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [project]))

                let buildDescriptionID = try await createIndexBuildDescription(workspace, session: testSession)

                func configuredTarget(for target: TestStandardTarget, using runDestination: SWBRunDestinationInfo? = nil) async throws -> SWBConfiguredTargetIdentifier {
                    let result = try await configuredTargets(for: [target], using: runDestination)
                    return try #require(result.only)
                }

                func configuredTargets(for targets: [TestStandardTarget], using runDestination: SWBRunDestinationInfo? = nil) async throws -> [SWBConfiguredTargetIdentifier] {
                    var request = SWBBuildRequest()
                    request.parameters.activeRunDestination = runDestination
                    request.enableIndexBuildArena = true

                    return try await testSession.session.selectConfiguredTargetsForIndex(targets: targets.map { SWBTargetGUID(rawValue: $0.guid) }, buildDescription: .init(buildDescriptionID), buildRequest: request)
                }

                let macOSAppForMacOSRef = try await configuredTarget(for: macOSAppTarget, using: .macOS)
                #expect(macOSAppForMacOSRef.rawGUID.contains("macosx"))

                let macOSAppForiOSRef = try await configuredTarget(for: macOSAppTarget, using: .iOS)
                #expect(macOSAppForiOSRef.rawGUID.contains("macosx"))

                let iOSAppRefNoDestination = try await configuredTarget(for: iOSAppTarget)
                #expect(iOSAppRefNoDestination.rawGUID.contains("macosx"))

                let iOSAppForMacOSRef = try await configuredTarget(for: iOSAppTarget, using: .macOS)
                #expect(iOSAppForMacOSRef.rawGUID.contains("macosx"))

                let iOSAppForiOSRef = try await configuredTarget(for: iOSAppTarget, using: .iOS)
                #expect(iOSAppForiOSRef.rawGUID.contains("iphoneos"))

                let iOSAppForUnsupportedRef = try await configuredTarget(for: iOSAppTarget, using: .watchOS)
                #expect(iOSAppForUnsupportedRef.rawGUID.contains("macosx"))

                let multiple = try await configuredTargets(for: [macOSAppTarget, iOSAppTarget], using: .macOS)
                #expect(multiple.count == 2)
                do {
                    let macOSAppGUID = try #require(multiple.first?.targetGUID.rawValue)
                    let iOSAppGUID = try #require(multiple.last?.targetGUID.rawValue)
                    #expect(macOSAppGUID == macOSAppTarget.guid)
                    #expect(iOSAppGUID == iOSAppTarget.guid)
                }
            }
        }
    }
}

fileprivate extension SWBBuildServiceSession {
    func createBuildDescription(buildRequest: SWBBuildRequest) async throws -> SWBBuildDescriptionID {
        var buildDescriptionID: SWBBuildDescriptionID?
        let buildDescriptionOperation = try await self.createBuildOperationForBuildDescriptionOnly(
            request: buildRequest,
            delegate: TestBuildOperationDelegate()
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
        return buildDescriptionID
    }
}
