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
import SWBTestSupport
import SwiftBuildTestSupport

import SWBUtil
import SwiftBuild

@Suite(.requireHostOS(.macOS))
fileprivate struct LocalizationInfoSymbolGenTests {

    @Test(.requireSDKs(.macOS))
    func includesSymbolFiles() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let target = TestStandardTarget(
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.count == 1)
                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.first?.key.hasSuffix("Localizable.xcstrings") ?? false)
                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.first?.value.count == 1)
                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.first?.value.first?.hasSuffix("GeneratedStringSymbols_Localizable.swift") ?? false)
                #expect(targetInfo.effectivePlatformName == "macosx")
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func XCStringsNotNeedingBuilt() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let target = TestStandardTarget(
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                // Return empty paths from xcstringstool compile --dryrun, which means we won't actually generate any tasks for it.
                // But we still need to detect its presence as part of the build inputs.
                let delegate = BuildOperationDelegate(returnEmpty: true)

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.count == 1)
                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.first?.key.hasSuffix("Localizable.xcstrings") ?? false)
                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.first?.value.count == 1)
                #expect(targetInfo.generatedSymbolFilesByXCStringsPath.first?.value.first?.hasSuffix("GeneratedStringSymbols_Localizable.swift") ?? false)
                #expect(targetInfo.effectivePlatformName == "macosx")
            }
        }
    }

}

private final class BuildOperationDelegate: SWBLocalizationDelegate {
    private let delegate = TestBuildOperationDelegate()
    private let returnEmpty: Bool

    init(returnEmpty: Bool = false) {
        self.returnEmpty = returnEmpty
    }

    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
        return await delegate.provisioningTaskInputs(targetGUID: targetGUID, provisioningSourceData: provisioningSourceData)
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SWBExternalToolResult {
        guard let command = commandLine.first, command.hasSuffix("xcstringstool") else {
            return .deferred
        }

        guard !returnEmpty else {
            // We were asked to return empty, simulating an xcstrings file that does not need to build at all.
            return .result(status: .exit(0), stdout: Data(), stderr: Data())
        }

        // We need to intercept and handle xcstringstool compile --dry-run commands.
        // These tests are not testing the XCStringsCompiler, we just need to produce something so the build plan doesn't fail.
        // So we'll just produce a single same-named .strings file.

        // Last arg is input.
        guard let inputPath = commandLine.last.map(Path.init) else {
            return .result(status: .exit(1), stdout: Data(), stderr: "Couldn't find input file in command line.".data(using: .utf8)!)
        }

        // Second to last arg is output directory.
        guard let outputDir = commandLine[safe: commandLine.endIndex - 2].map(Path.init) else {
            return .result(status: .exit(1), stdout: Data(), stderr: "Couldn't find output directory in command line.".data(using: .utf8)!)
        }

        let output = outputDir.join("en.lproj/\(inputPath.basenameWithoutSuffix).strings")

        return .result(status: .exit(0), stdout: Data(output.str.utf8), stderr: Data())
    }
}
