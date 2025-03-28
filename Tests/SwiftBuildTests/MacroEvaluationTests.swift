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

/// Test evaluating both using a scope, and directly against the model objects.
@Suite
fileprivate struct MacroEvaluationTests {
    @Test
    func macroEvaluationBasics() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testTarget = TestExternalTarget("ExternalTarget")
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo"),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])

                try await testSession.sendPIF(testWorkspace)
                let session = testSession.session

                let buildParameters = SWBBuildParameters()

                // Evaluate directly against the model objects.
                do {
                    let level = SWBMacroEvaluationLevel.project(testProject.guid)

                    expectEqual(try await session.evaluateMacroAsString("PROJECT", level: level, buildParameters: buildParameters, overrides: [:]), "aProject")
                    #expect(try await !session.evaluateMacroAsBoolean("PROJECT", level: level, buildParameters: buildParameters, overrides: [:]))
                    expectEqual(try await session.evaluateMacroAsStringList("PROJECT", level: level, buildParameters: buildParameters, overrides: [:]), ["aProject"])
                    expectEqual(try await session.evaluateMacroAsString("TARGET_NAME", level: level, buildParameters: buildParameters, overrides: [:]), "")
                    #expect(try await !session.evaluateMacroAsBoolean("TARGET_NAME", level: level, buildParameters: buildParameters, overrides: [:]))
                    expectEqual(try await session.evaluateMacroAsStringList("TARGET_NAME", level: level, buildParameters: buildParameters, overrides: [:]), [""])
                    expectEqual(try await session.evaluateMacroAsStringList("HEADER_SEARCH_PATHS", level: level, buildParameters: buildParameters, overrides: [:]), [])
                    #expect(try await !session.evaluateMacroAsBoolean("HEADER_SEARCH_PATHS", level: level, buildParameters: buildParameters, overrides: [:]))
                    expectEqual(try await session.evaluateMacroAsString("HEADER_SEARCH_PATHS", level: level, buildParameters: buildParameters, overrides: [:]), "")
                    #expect(try await session.evaluateMacroAsBoolean("INFOPLIST_EXPAND_BUILD_SETTINGS", level: level, buildParameters: buildParameters, overrides: [:]))
                    expectEqual(try await session.evaluateMacroAsStringList("INFOPLIST_EXPAND_BUILD_SETTINGS", level: level, buildParameters: buildParameters, overrides: [:]), ["YES"])
                    expectEqual(try await session.evaluateMacroAsString("INFOPLIST_EXPAND_BUILD_SETTINGS", level: level, buildParameters: buildParameters, overrides: [:]), "YES")
                    await #expect(throws: (any Error).self) {
                        try await session.evaluateMacroAsBoolean("DOES_NOT_EXIST", level: level, buildParameters: buildParameters, overrides: [:])
                    }
                    await #expect(throws: (any Error).self) {
                        try await session.evaluateMacroAsString("DOES_NOT_EXIST", level: level, buildParameters: buildParameters, overrides: [:])
                    }
                    await #expect(throws: (any Error).self) {
                        try await session.evaluateMacroAsStringList("DOES_NOT_EXIST", level: level, buildParameters: buildParameters, overrides: [:])
                    }
                }

                do {
                    let level = SWBMacroEvaluationLevel.target(testTarget.guid)

                    expectEqual(try await session.evaluateMacroAsString("TARGET_NAME", level: level, buildParameters: buildParameters, overrides: [:]), "ExternalTarget")
                    #expect(try await !session.evaluateMacroAsBoolean("TARGET_NAME", level: level, buildParameters: buildParameters, overrides: [:]))
                    expectEqual(try await session.evaluateMacroAsStringList("TARGET_NAME", level: level, buildParameters: buildParameters, overrides: [:]), ["ExternalTarget"])
                }
            }
        }
    }

    @Test(.requireSDKs(.host), .userDefaults(["EnablePluginManagerLogging": "0"]))
    func macroEvaluationAdvanced() async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = tmpDir.str

                // Create a service and session.
                let service = try await SWBBuildService()
                await deferrable.addBlock {
                    await service.close()
                }

                await deferrable.addBlock {
                    // Verify there are no sessions remaining.
                    do {
                        expectEqual(try await service.listSessions(), [:])
                    } catch {
                        Issue.record(error)
                    }
                }

                let (result, diagnostics) = await service.createSession(name: "FOO", cachePath: tmpDirPath)
                #expect(diagnostics.isEmpty)
                let session = try result.get()
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await session.close()
                    }
                }

                // Send a PIF (required to establish a workspace context).
                //
                // FIXME: Move this test data elsewhere.
                let projectDir = "\(tmpDirPath)/SomeProject"
                let projectFilesDir = "\(projectDir)/SomeFiles"

                let workspacePIF: SWBPropertyListItem = [
                    "guid":     "some-workspace-guid",
                    "name":     "aWorkspace",
                    "path":     .plString("\(tmpDirPath)/aWorkspace.xcworkspace/contents.xcworkspacedata"),
                    "projects": ["P1"]
                ]
                let projectPIF: SWBPropertyListItem = [
                    "guid": "P1",
                    "path": .plString("\(projectDir)/aProject.xcodeproj"),
                    "groupTree": [
                        "guid": "G1",
                        "type": "group",
                        "name": "SomeFiles",
                        "sourceTree": "PROJECT_DIR",
                        "path": .plString(projectFilesDir),
                    ],
                    "buildConfigurations": [[
                        "guid": "BC1",
                        "name": "Config1",
                        "buildSettings": [
                            "OTHER_CFLAGS": "$(inherited) -DPROJECT",
                        ]
                    ]],
                    "defaultConfigurationName": "Config1",
                    "developmentRegion": "English",
                    "targets": ["T1"]
                ]
                let targetPIF: SWBPropertyListItem = [
                    "guid": "T1",
                    "name": "Target1",
                    "type": "standard",
                    "productTypeIdentifier": "com.apple.product-type.tool",
                    "productReference": [
                        "guid": "PR1",
                        "name": "MyApp",
                    ],
                    "buildPhases": [],
                    "buildConfigurations": [[
                        "guid": "C2",
                        "name": "Config1",
                        "buildSettings": [
                            "PRODUCT_NAME": "MyApp",
                            "IS_TRUE": "YES",
                            "IS_FALSE": "NO",
                            "OTHER_CFLAGS": "$(inherited) -DTARGET",
                            "FLEXIBLE": "$(A) $(B) $(C)",
                            "A": "A",
                            "B": "B",
                            "C": "C",
                        ]
                    ]],
                    "dependencies": [],
                    "buildRules": [],
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

                // Set the system and user info.
                try await session.setSystemInfo(.defaultForTesting)

                let userInfo = SWBUserInfo.defaultForTesting
                try await session.setUserInfo(userInfo)

                // Create a build request.
                var parameters = SWBBuildParameters()
                parameters.action = "build"
                parameters.configurationName = "Config1"

                // Evaluate directly against the target.
                let level = SWBMacroEvaluationLevel.target("T1")

                let hostOperatingSystem = try ProcessInfo.processInfo.hostOperatingSystem()
                let executableName = hostOperatingSystem.imageFormat.executableName(basename: "MyApp")

                // Evaluate some macros as strings.
                await #expect(throws: (any Error).self) {
                    try await session.evaluateMacroAsString("UNDEFINED_MACRO", level: level, buildParameters: parameters, overrides: [:])
                }
                expectEqual(try await session.evaluateMacroAsString("USER", level: level, buildParameters: parameters, overrides: [:]), userInfo.userName)
                expectEqual(try await session.evaluateMacroAsString("PRODUCT_NAME", level: level, buildParameters: parameters, overrides: [:]), "MyApp")
                expectEqual(try await session.evaluateMacroAsString("TARGET_NAME", level: level, buildParameters: parameters, overrides: [:]), "Target1")
                expectEqual(try await session.evaluateMacroAsString("CONFIGURATION", level: level, buildParameters: parameters, overrides: [:]), "Config1")
                expectEqual(try await session.evaluateMacroAsString("IS_TRUE", level: level, buildParameters: parameters, overrides: [:]), "YES")
                expectEqual(try await session.evaluateMacroAsString("IS_FALSE", level: level, buildParameters: parameters, overrides: [:]), "NO")
                expectEqual(try await session.evaluateMacroAsString("OTHER_CFLAGS", level: level, buildParameters: parameters, overrides: [:]), " -DPROJECT -DTARGET")
                // Evaluate some macros as booleans.
                #expect(try await session.evaluateMacroAsBoolean("IS_TRUE", level: level, buildParameters: parameters, overrides: [:]))
                #expect(try await !session.evaluateMacroAsBoolean("IS_FALSE", level: level, buildParameters: parameters, overrides: [:]))
                await #expect(throws: (any Error).self) {
                    try await session.evaluateMacroAsBoolean("UNDEFINED_MACRO", level: level, buildParameters: parameters, overrides: [:])
                }
                #expect(try await !session.evaluateMacroAsBoolean("PRODUCT_NAME", level: level, buildParameters: parameters, overrides: [:]))

                // Evaluate some macros as string lists.
                expectEqual(try await session.evaluateMacroAsStringList("OTHER_CFLAGS", level: level, buildParameters: parameters, overrides: [:]), ["-DPROJECT", "-DTARGET"])
                // Evaluate some macro expressions as strings.
                let platformName = try await session.evaluateMacroAsString("EFFECTIVE_PLATFORM_NAME", level: level, buildParameters: parameters, overrides: [:])
                expectEqual(try await session.evaluateMacroExpressionAsString("The name of the product is $(FULL_PRODUCT_NAME)", level: level, buildParameters: parameters, overrides: [:]), "The name of the product is \(executableName)")
                #expect((try await session.evaluateMacroExpressionAsString("$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)", level: level, buildParameters: parameters, overrides: [:])).hasSuffix(Path("build/Config1\(platformName)").str + "/" + executableName))

                // Evaluate some macro expressions as string lists.
                expectEqual(try await session.evaluateMacroExpressionAsStringList("$(FULL_PRODUCT_NAME)", level: level, buildParameters: parameters, overrides: [:]), [executableName])
                expectEqual(try await session.evaluateMacroExpressionArrayAsStringList(["$(A)", "$(B)"], level: level, buildParameters: parameters, overrides: [:]), ["A", "B"])
                // Evaluate an array of macro expressions as individual strings.
                expectEqual(try await session.evaluateMacroExpressionArrayAsStringList(["$(A)", "$(B)", "$(IS_TRUE)"], level: level, buildParameters: parameters, overrides: [:]), ["A", "B", "YES"])
                // Test using overrides.
                expectEqual(try await session.evaluateMacroAsString("FLEXIBLE", level: level, buildParameters: parameters, overrides: [:]), "A B C")
                expectEqual(try await session.evaluateMacroAsString("FLEXIBLE", level: level, buildParameters: parameters, overrides: ["A": "D"]), "D B C")
                expectEqual(try await session.evaluateMacroAsString("FLEXIBLE", level: level, buildParameters: parameters, overrides: ["B": "$(PRODUCT_NAME)"]), "A MyApp C")
                expectEqual(try await session.evaluateMacroExpressionAsStringList("$(FLEXIBLE)", level: level, buildParameters: parameters, overrides: ["C": "X Y"]), ["A", "B", "X", "Y"])
            }
        }
    }
}
