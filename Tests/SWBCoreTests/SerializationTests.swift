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
import SWBUtil
import SWBProtocol
@_spi(Testing) import SWBCore
import SWBMacro

@Suite fileprivate struct SerializationTests: CoreBasedTests {
    struct MacroEvaluationScopeDeserializerDelegate: MacroValueAssignmentTableDeserializerDelegate
    {
        let namespace: MacroNamespace
    }

    /// Test serializing a simple `MacroEvaluationScope`.
    @Test
    func macroEvaluationScopeSerialization() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        let param = namespace.declareConditionParameter("platform")
        var table = MacroValueAssignmentTable(namespace: namespace)

        // Declare some string macros.
        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")
        let Z = try namespace.declareStringMacro("Z")
        let EMPTY = try namespace.declareStringMacro("EMPTY")

        // Declare some string list macros.
        let XYZ = try namespace.declareStringListMacro("XYZ")
        let XZ = try namespace.declareStringListMacro("XZ")
        let EMPTY_ARRAY = try namespace.declareStringListMacro("EMPTY_ARRAY")

        // Declare some boolean macros.
        let A = try namespace.declareBooleanMacro("A")
        let B = try namespace.declareBooleanMacro("B")

        // Declare some user-defined macros.
        let U = try namespace.declareUserDefinedMacro("U")

        // Declare some macros to be used to exercise conditions.
        let C = try namespace.declareStringMacro("C")

        // Push some assignments.
        table.push(X, literal: "x")
        table.push(Y, literal: "y")
        table.push(Z, literal: "z")
        table.push(EMPTY, literal: "")
        table.push(XYZ, namespace.parseStringList("$(X) $(Y) $(Z)"))
        table.push(XZ, namespace.parseStringList("$(X) $(Z)"))
        table.push(EMPTY_ARRAY, literal: [])
        table.push(A, literal: true)
        table.push(B, literal: false)
        table.push(U, namespace.parseForMacro(U, value: "u"))
        table.push(C, literal: "MAC", conditions: MacroConditionSet(conditions: [MacroCondition(parameter:param, valuePattern:"macosx")]))
        table.push(C, literal: "IOS", conditions: MacroConditionSet(conditions: [MacroCondition(parameter:param, valuePattern:"iphoneos")]))

        // Create a macro evaluation scope for testing.
        let scope = MacroEvaluationScope(table: table, conditionParameterValues: [param: ["iphoneos"]])

        // Serialize!
        let sz = MsgPackSerializer()
        sz.serialize(scope)

        // Deserialize!
        // We re-use the namespace here since these are simple tests.
        let dsz = MsgPackDeserializer(sz.byteString, delegate:MacroEvaluationScopeDeserializerDelegate(namespace: namespace))
        let dszScope: MacroEvaluationScope = try dsz.deserialize()
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as String
        }                // Next element is not a String
        // Nothing left to deserialize.

        // Test that we get expected and identical values from both scopes.
        #expect(scope.evaluate(X) == "x")
        #expect(scope.evaluate(X) == dszScope.evaluate(X))
        #expect(scope.evaluate(Y) == "y")
        #expect(scope.evaluate(Y) == dszScope.evaluate(Y))
        #expect(scope.evaluate(Z) == "z")
        #expect(scope.evaluate(Z) == dszScope.evaluate(Z))
        #expect(scope.evaluate(EMPTY) == "")
        #expect(scope.evaluate(EMPTY) == dszScope.evaluate(EMPTY))
        #expect(scope.evaluate(XYZ) == ["x", "y", "z"])
        #expect(scope.evaluate(XYZ) == dszScope.evaluate(XYZ))
        #expect(scope.evaluate(XZ) == ["x", "z"])
        #expect(scope.evaluate(XZ) == dszScope.evaluate(XZ))
        #expect(scope.evaluate(EMPTY_ARRAY) == [])
        #expect(scope.evaluate(EMPTY_ARRAY) == dszScope.evaluate(EMPTY_ARRAY))
        #expect(scope.evaluate(A))
        #expect(scope.evaluate(A) == dszScope.evaluate(A))
        #expect(!scope.evaluate(B))
        #expect(scope.evaluate(B) == dszScope.evaluate(B))
        #expect(scope.evaluateAsString(U) == "u")                              // MacroEvaluationScope doesn't support evaluate() for user-defined macros
        #expect(scope.evaluateAsString(U) == dszScope.evaluateAsString(U))
        #expect(scope.evaluate(C) == "IOS")
        #expect(scope.evaluate(C) == dszScope.evaluate(C))
    }

    /// Test serializing the settings for a scope for a simple project with some overriding parameters.
    @Test(.skipHostOS(.windows, "seems to hit an assertion in evaluating the :relativeto operator"))
    func basicProjectSettingsSerialization() async throws {
        let testWorkspaceData = TestWorkspace("Workspace",
                                              projects:
                                                [
                                                    TestProject("aProject",
                                                                groupTree: TestGroup("SomeFiles"),
                                                                buildConfigurations:
                                                                    [
                                                                        TestBuildConfiguration("Debug", buildSettings:
                                                                                                [
                                                                                                    "BAZ": "project-$(inherited)",
                                                                                                    "PROJECT_LEVEL": "project",
                                                                                                ]),
                                                                    ],
                                                                targets:
                                                                    [
                                                                        TestAggregateTarget("AggregateTarget",
                                                                                            buildConfigurations:
                                                                                                [
                                                                                                    TestBuildConfiguration("Debug", buildSettings:
                                                                                                                            [
                                                                                                                                "BAZ": "target-$(inherited)",
                                                                                                                                "TARGET_LEVEL": "target",
                                                                                                                            ]),
                                                                                                ]),
                                                                    ]),
                                                ])

        let core = try await getCore()
        let context = try WorkspaceContext(core: core, workspace: testWorkspaceData.load(core), processExecutionCache: .sharedForTesting)
        context.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid:12345, home: Path("/Users/exampleUser"), environment: ["BAZ": "environment-$(inherited)"]))
        let buildRequestContext = BuildRequestContext(workspaceContext: context)

        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(
            action: .build,
            configuration: "Debug",
            overrides: ["BAZ": "overrides-$(inherited)"],
            commandLineOverrides: ["BAZ": "commandline-$(inherited)"],
            commandLineConfigOverridesPath: nil,
            commandLineConfigOverrides: ["BAZ": "commandlineconfig-$(inherited)"],
            environmentConfigOverridesPath: nil,
            environmentConfigOverrides: ["BAZ": "environmentconfig-$(inherited)"])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        let scope = settings.globalScope

        // Serialize!
        let sz = MsgPackSerializer()
        sz.serialize(scope)

        // Deserialize!
        // Create a new namespace which is a child of the workspace's namespace, which will be a peer to the settings object's namespace.  This gets us some coverage of declaring macros in a new namespace.
        let dszNamespace = MacroNamespace(parent: context.workspace.userNamespace, debugDescription: "deserializer")
        let dsz = MsgPackDeserializer(sz.byteString, delegate:MacroEvaluationScopeDeserializerDelegate(namespace: dszNamespace))
        let dszScope: MacroEvaluationScope = try dsz.deserialize()
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as String
        }                // Next element is not a String
        // Nothing left to deserialize.

        let macroName = "PROJECT_LEVEL"
        let baseMacro = settings.userNamespace.lookupMacroDeclaration(macroName)!
        let baseValue = scope.evaluateAsString(baseMacro)
        let dszMacro = dszNamespace.lookupMacroDeclaration(macroName)!
        let dszValue = dszScope.evaluateAsString(dszMacro)
        #expect(baseMacro.type == dszMacro.type, "Evaluated string value for '\(macroName)' (type \(baseMacro.type)) in original scope ('\(baseValue)') does not equal value from deserialized scope ('\(dszValue)').")
        #expect(baseValue == dszValue)

        // Iterate through all of the settings in the original settings scope, and check that they evaluate to the same value in the deserialized scope.
        for settingsMacro in scope.table.valueAssignments.keys
        {
            if let dszMacro = dszNamespace.lookupMacroDeclaration(settingsMacro.name)
            {
                if settingsMacro.type == dszMacro.type
                {
                    // We use evaluateAsString() here to keep the logic simple.
                    let settingsValue = scope.evaluateAsString(settingsMacro)
                    let dszValue = dszScope.evaluateAsString(dszMacro)
                    #expect(settingsValue == dszValue)
                }
                else
                {
                    Issue.record("Macro '\(settingsMacro.name)' is of type \(settingsMacro.type) in original settings namespace, but type \(dszMacro.type) in deserializer namespace.")
                }
            }
            else
            {
                Issue.record("Could not find macro '\(settingsMacro.name)' (type \(settingsMacro.type)) in deserializer namespace.")
            }
        }
    }
}
