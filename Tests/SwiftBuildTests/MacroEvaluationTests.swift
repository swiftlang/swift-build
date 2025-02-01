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
@Suite(.requireHostOS(.macOS))
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

                // Evaluate using a scope.
                do {
                    // Get the project macro scope.
                    let scope = try await session.createMacroEvaluationScope(level: .project(testProject.guid), buildParameters: buildParameters)

                    expectEqual(try await scope.evaluateMacroAsString("PROJECT"), "aProject")
                    #expect(try await !scope.evaluateMacroAsBool("PROJECT"))
                    expectEqual(try await scope.evaluateMacroAsStringList("PROJECT"), ["aProject"])
                    expectEqual(try await scope.evaluateMacroAsString("TARGET_NAME"), "")
                    #expect(try await !scope.evaluateMacroAsBool("TARGET_NAME"))
                    expectEqual(try await scope.evaluateMacroAsStringList("TARGET_NAME"), [""])
                    expectEqual(try await scope.evaluateMacroAsStringList("HEADER_SEARCH_PATHS"), [])
                    #expect(try await !scope.evaluateMacroAsBool("HEADER_SEARCH_PATHS"))
                    expectEqual(try await scope.evaluateMacroAsString("HEADER_SEARCH_PATHS"), "")
                    #expect(try await scope.evaluateMacroAsBool("INFOPLIST_EXPAND_BUILD_SETTINGS"))
                    expectEqual(try await scope.evaluateMacroAsStringList("INFOPLIST_EXPAND_BUILD_SETTINGS"), ["YES"])
                    expectEqual(try await scope.evaluateMacroAsString("INFOPLIST_EXPAND_BUILD_SETTINGS"), "YES")
                    await #expect(throws: (any Error).self) {
                        try await scope.evaluateMacroAsBool("DOES_NOT_EXIST")
                    }
                    await #expect(throws: (any Error).self) {
                        try await scope.evaluateMacroAsString("DOES_NOT_EXIST")
                    }
                    await #expect(throws: (any Error).self) {
                        try await scope.evaluateMacroAsStringList("DOES_NOT_EXIST")
                    }
                }

                do {
                    // Get the target macro scope.
                    let scope = try await session.createMacroEvaluationScope(level: .target(testTarget.guid), buildParameters: buildParameters)

                    expectEqual(try await scope.evaluateMacroAsString("TARGET_NAME"), "ExternalTarget")
                    #expect(try await !scope.evaluateMacroAsBool("TARGET_NAME"))
                    expectEqual(try await scope.evaluateMacroAsStringList("TARGET_NAME"), ["ExternalTarget"])
                }

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

    @Test(.requireSDKs(.macOS), .userDefaults(["EnablePluginManagerLogging": "0"]))
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
                    "productTypeIdentifier": "com.apple.product-type.application",
                    "productReference": [
                        "guid": "PR1",
                        "name": "MyApp.app",
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

                // Create a build request and get a macro evaluation scope.
                var parameters = SWBBuildParameters()
                parameters.action = "build"
                parameters.configurationName = "Config1"

                // Evaluate using a scope.
                let scope = try await session.createMacroEvaluationScope(level: .target("T1"), buildParameters: parameters)

                // Evaluate some macros as strings.
                await #expect(throws: (any Error).self) {
                    try await scope.evaluateMacroAsString("UNDEFINED_MACRO", overrides: nil)
                }
                expectEqual(try await scope.evaluateMacroAsString("USER", overrides: nil), userInfo.userName)
                expectEqual(try await scope.evaluateMacroAsString("PRODUCT_NAME", overrides: nil), "MyApp")
                expectEqual(try await scope.evaluateMacroAsString("TARGET_NAME", overrides: nil), "Target1")
                expectEqual(try await scope.evaluateMacroAsString("CONFIGURATION", overrides: nil), "Config1")
                expectEqual(try await scope.evaluateMacroAsString("IS_TRUE", overrides: nil), "YES")
                expectEqual(try await scope.evaluateMacroAsString("IS_FALSE", overrides: nil), "NO")
                expectEqual(try await scope.evaluateMacroAsString("OTHER_CFLAGS", overrides: nil), " -DPROJECT -DTARGET")
                // Evaluate some macros as booleans.
                #expect(try await scope.evaluateMacroAsBool("IS_TRUE"))
                #expect(try await !scope.evaluateMacroAsBool("IS_FALSE"))
                await #expect(throws: (any Error).self) {
                    try await scope.evaluateMacroAsBool("UNDEFINED_MACRO")
                }
                #expect(try await !scope.evaluateMacroAsBool("PRODUCT_NAME"))

                // Evaluate some macros as string lists.
                expectEqual(try await scope.evaluateMacroAsStringList("OTHER_CFLAGS"), ["-DPROJECT", "-DTARGET"])
                // Evaluate some macro expressions as strings.
                expectEqual(try await scope.evaluateMacroExpressionAsString("The name of the product is $(FULL_PRODUCT_NAME)"), "The name of the product is MyApp.app")

                #expect((try await scope.evaluateMacroExpressionAsString("$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)")).hasSuffix("build/Config1/MyApp.app/Contents/MacOS/MyApp"))

                // Evaluate some macro expressions as string lists.
                expectEqual(try await scope.evaluateMacroExpressionAsStringList("$(FULL_PRODUCT_NAME)"), ["MyApp.app"])
                expectEqual(try await scope.evaluateMacroExpressionArrayAsStringList(["$(A)", "$(B)"]), ["A", "B"])
                // Evaluate an array of macro expressions as individual strings.
                expectEqual(try await scope.evaluateMacroExpressionArrayAsStringList(["$(A)", "$(B)", "$(IS_TRUE)"]), ["A", "B", "YES"])
                // Test using overrides.
                expectEqual(try await scope.evaluateMacroAsString("FLEXIBLE"), "A B C")
                expectEqual(try await scope.evaluateMacroAsString("FLEXIBLE", overrides: ["A": "D"]), "D B C")
                expectEqual(try await scope.evaluateMacroAsString("FLEXIBLE", overrides: ["B": "$(PRODUCT_NAME)"]), "A MyApp C")
                expectEqual(try await scope.evaluateMacroExpressionAsStringList("$(FLEXIBLE)", overrides: ["C": "X Y"]), ["A", "B", "X", "Y"])
                // Evaluate directly against the target.
                let level = SWBMacroEvaluationLevel.target("T1")

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
                expectEqual(try await session.evaluateMacroExpressionAsString("The name of the product is $(FULL_PRODUCT_NAME)", level: level, buildParameters: parameters, overrides: [:]), "The name of the product is MyApp.app")
                #expect((try await session.evaluateMacroExpressionAsString("$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)", level: level, buildParameters: parameters, overrides: [:])).hasSuffix("build/Config1/MyApp.app/Contents/MacOS/MyApp"))

                // Evaluate some macro expressions as string lists.
                expectEqual(try await session.evaluateMacroExpressionAsStringList("$(FULL_PRODUCT_NAME)", level: level, buildParameters: parameters, overrides: [:]), ["MyApp.app"])
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
