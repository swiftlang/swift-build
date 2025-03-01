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
import SWBLibc
import SWBCore
import SWBTaskExecution
import SWBMacro

// This test suite is a lot less interesting than it used to be since the tool is no longer responsible for evaluating build settings in the entitlements file.  There is some additional functionality we can test in the tool once the FIXMEs for that functionality have been addressed.
//
/// Test `ProcessProductEntitlementsTaskAction` functionality.
@Suite
fileprivate struct ProcessProductEntitlementsTaskTests {
    @Test
    func diagnostics() async {
        func checkDiagnostics(_ commandLine: [String], errors: [String] = [], warnings: [String] = [], notes: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) async
        {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            let table = MacroValueAssignmentTable(namespace: namespace)
            let scope = MacroEvaluationScope(table: table)
            let action = ProcessProductEntitlementsTaskAction(scope: scope, fs: PseudoFS(), entitlements: .plDict([:]), entitlementsVariant: .signed, destinationPlatformName: "iphoneos", entitlementsFilePath: nil)
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: Path(""), action: action)
            let executionDelegate = MockExecutionDelegate()
            let outputDelegate = MockTaskOutputDelegate()

            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            #expect(result == .failed, sourceLocation: sourceLocation)
            #expect(outputDelegate.errors == errors.map { "error: \($0)" }, sourceLocation: sourceLocation)
            #expect(outputDelegate.warnings == warnings.map { "warning: \($0)" }, sourceLocation: sourceLocation)
            #expect(outputDelegate.notes == notes.map { "note: \($0)" }, sourceLocation: sourceLocation)
        }

        await checkDiagnostics([], errors: ["missing required option: -entitlements", "missing required option: -o"])
        await checkDiagnostics(["productPackagingUtility", "-entitlements", "foo"], errors: ["missing required option: -o"])
        await checkDiagnostics(["productPackagingUtility", "-entitlements", "foo", "-o"], errors: ["missing argument for option: -o"])
        await checkDiagnostics(["productPackagingUtility", "-entitlements", "foo", "-o", "bar", "baz"], errors: ["multiple input paths specified"])
        await checkDiagnostics(["productPackagingUtility", "foo", "-o", "bar"], errors: ["missing required option: -entitlements"])
        await checkDiagnostics(["productPackagingUtility", "-entitlements", "-bogus", "foo", "-o", "bar"], errors: ["unrecognized argument: -bogus"])
    }

    /// Test the basics of processing the entitlements for an iOS app.
    @Test
    func entitlementsBasics() async throws {
        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Definitions of data in the entitlements file.
        let appIdentifierPrefix = "F154D0C"
        let teamIdentifierPrefix = appIdentifierPrefix
        let appIdentifier = "\(appIdentifierPrefix).com.apple.dt.iOSApp"

        // Define a mock input file.
        let input = Path.root.join("Entitlements.plist")

        // TODO: Presently we are not testing the expanded app entitlements.

        // Set up the entitlements data.  This data normally comes from the provisioning task inputs.
        let entitlementsData: [String: any PropertyListItemConvertible] = [
            "application-identifier": appIdentifier,
            "com.apple.developer.team-identifier": teamIdentifierPrefix,
            "get-task-allow": true,
            "keychain-access-groups": [
                appIdentifier
            ],
        ]

        let entitlements = PropertyListItem(entitlementsData)

        // Create a MacroEvaluationScope for the tool to use to evaluate build settings.
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "testEntitlementsBasics()")
        let table = MacroValueAssignmentTable(namespace: namespace)
        // Any overrides desired should be pushed here.
        let scope = MacroEvaluationScope(table: table)

        // Define the location of the output file.
        let output = Path.root.join("dst/iOSApp.app.xcent")
        try executionDelegate.fs.createDirectory(output.dirname)

        let action = ProcessProductEntitlementsTaskAction(scope: scope, fs: PseudoFS(), entitlements: entitlements, entitlementsVariant: .signed, destinationPlatformName: "iphoneos", entitlementsFilePath: nil)
        var builder = PlannedTaskBuilder(type: mockTaskType, ruleInfo: [], commandLine: ["productPackagingUtility", "-entitlements", "-format", "xml", input.str, "-o", output.str].map{ .literal(ByteString(encodingAsUTF8: $0)) })
        let task = Task(&builder)
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the command succeeded with no errors.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Examine the contents of the output file.
        let outputContents = try executionDelegate.fs.read(output)
        guard let outputPlist = try? PropertyList.fromBytes(outputContents.bytes) else {
            Issue.record("unable to read entitlements file")
            return
        }
        guard case .plDict(let dict) = outputPlist else {
            Issue.record("entitlements content is not a dictionary")
            return
        }
        #expect(dict.count == 4)
        if case .plString(let appId)? = dict["application-identifier"] {
            #expect(appId == appIdentifier)
        }
        else {
            Issue.record("missing 'application-identifier'")
        }
        if case .plString(let teamId)? = dict["com.apple.developer.team-identifier"] {
            #expect(teamId == teamIdentifierPrefix)
        }
        else {
            Issue.record("missing 'com.apple.developer.team-identifier'")
        }

        #expect(dict["get-task-allow"]?.boolValue == true)

        if case .plArray(let kcGroups)? = dict["keychain-access-groups"] {
            #expect(kcGroups.count == 1)
            if case .plString(let kcGroup) = kcGroups[0] {
                #expect(kcGroup == appIdentifier)
            }
            else {
                Issue.record("empty 'keychain-access-groups'")
            }
        }
        else {
            Issue.record("missing 'keychain-access-groups'")
        }
    }

    // For a macOS (only) app, special entitlements will be added if building for testing or profiling.
    @Test
    func macOSEntitlements() async throws {
        func performTest(_ schemeCommand: SchemeCommand, _ destinationPlatformName: String, additionalEntitlements: [String: PropertyListItem] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let testInputs = "schemeCommand: \(schemeCommand), destinationPlatformName: \(destinationPlatformName), additionalEntitlements: \(String(describing: additionalEntitlements))"

            let executionDelegate = MockExecutionDelegate(schemeCommand: schemeCommand)
            let outputDelegate = MockTaskOutputDelegate()

            // Definitions of data in the entitlements file.
            let appIdentifierPrefix = "F154D0C"
            let teamIdentifierPrefix = appIdentifierPrefix
            let appIdentifier = "\(appIdentifierPrefix).com.apple.dt.macOSApp"

            // Define a mock input file.
            let input = Path.root.join("Entitlements.plist")

            // Set up the entitlements data.  This data normally comes from the provisioning task inputs.
            let entitlements: [String: PropertyListItem] = [
                "application-identifier": .plString(appIdentifier),
                "com.apple.developer.team-identifier": .plString(teamIdentifierPrefix),
                "get-task-allow": true,
                "keychain-access-groups": [
                    appIdentifier
                ],
            ].merging(additionalEntitlements) { (_, new) in new }

            // Create a MacroEvaluationScope for the tool to use to evaluate build settings.
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "testEntitlementsBasics()")
            let table = MacroValueAssignmentTable(namespace: namespace)
            let scope = MacroEvaluationScope(table: table)

            // Define the location of the output file.
            let output = Path.root.join("dst/macOSApp.app.xcent")
            try executionDelegate.fs.createDirectory(output.dirname)

            let action = ProcessProductEntitlementsTaskAction(scope: scope, fs: PseudoFS(), entitlements: .plDict(entitlements), entitlementsVariant: .signed, destinationPlatformName: destinationPlatformName, entitlementsFilePath: nil)
            var builder = PlannedTaskBuilder(type: mockTaskType, ruleInfo: [], commandLine: ["productPackagingUtility", "-entitlements", "-format", "xml", input.str, "-o", output.str].map{ .literal(ByteString(encodingAsUTF8: $0)) })
            let task = Task(&builder)
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Check the command succeeded with no errors.
            #expect(result == .succeeded)
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])

            // Examine the contents of the output file for the additional content (only) based on the platform and scheme command.
            let outputContents = try executionDelegate.fs.read(output)
            guard let outputPlist = try? PropertyList.fromBytes(outputContents.bytes) else {
                Issue.record("unable to read entitlements file, test inputs: \(testInputs)", sourceLocation: sourceLocation)
                return
            }
            guard case .plDict(let dict) = outputPlist else {
                Issue.record("entitlements content for \(schemeCommand) scheme command is not a dictionary, test inputs: \(testInputs)", sourceLocation: sourceLocation)
                return
            }

            // For test and profile on macOS, check the additional keys.
            if destinationPlatformName == "macosx" && (schemeCommand == .test || schemeCommand == .profile) {
                let expectedFileSystemEntitlementKey = "com.apple.security.temporary-exception.files.absolute-path.read-only"
                let fileSystemEntitlementValue = dict[expectedFileSystemEntitlementKey]
                switch fileSystemEntitlementValue {
                case .plArray(let tmpExceptionFiles)?:
                    #expect(tmpExceptionFiles.contains(.plString("/")), "test inputs: \(testInputs)", sourceLocation: sourceLocation)
                default:
                    if let fileSystemEntitlementValue = fileSystemEntitlementValue {
                        Issue.record("unexpected entry '\(fileSystemEntitlementValue)' for key '\(expectedFileSystemEntitlementKey)', test inputs: \(testInputs)", sourceLocation: sourceLocation)
                    } else {
                        Issue.record("missing '\(expectedFileSystemEntitlementKey)', test inputs: \(testInputs)", sourceLocation: sourceLocation)
                    }
                }

                let expectedMachLookupEntitlementKey = "com.apple.security.temporary-exception.mach-lookup.global-name"
                let machLookupEntitlementValue = dict[expectedMachLookupEntitlementKey]
                switch machLookupEntitlementValue {
                case .plArray(let tmpExceptionMachLookups)?:
                    #expect(tmpExceptionMachLookups.contains(.plString("com.apple.testmanagerd")), "test inputs: \(testInputs)", sourceLocation: sourceLocation)
                    #expect(tmpExceptionMachLookups.contains(.plString("com.apple.dt.testmanagerd.runner")), "test inputs: \(testInputs)", sourceLocation: sourceLocation)
                    #expect(tmpExceptionMachLookups.contains(.plString("com.apple.coresymbolicationd")), "test inputs: \(testInputs)", sourceLocation: sourceLocation)
                default:
                    if let machLookupEntitlementValue = machLookupEntitlementValue {
                        Issue.record("unexpected entry '\(machLookupEntitlementValue)' for key '\(expectedMachLookupEntitlementKey)', test inputs: \(testInputs)", sourceLocation: sourceLocation)
                    } else {
                        Issue.record("missing '\(expectedMachLookupEntitlementKey)', test inputs: \(testInputs)", sourceLocation: sourceLocation)
                    }
                }
            }
            else {
                func assertKeyUnmodified(_ key: String, sourceLocation: SourceLocation = #_sourceLocation) {
                    let oldValue = entitlements[key]
                    let newValue = dict[key]

                    switch (oldValue, newValue) {
                    case (nil, nil):
                        break
                    case (.plString(let singleValue)?, .plString(let singlePlistValue)?):
                        if singleValue != singlePlistValue {
                            Issue.record("key '\(key)' was modified. oldValue: \(singleValue), newValue: \(singlePlistValue). test inputs: \(testInputs)", sourceLocation: sourceLocation)
                        }
                    case (.plArray(let array)?, .plArray(let arrayPlist)?):
                        let arrayValue = array.map { $0.stringValue }
                        let arrayPlistValue = arrayPlist.map { $0.stringValue }
                        if arrayValue != arrayPlistValue {
                            Issue.record("key '\(key)' was modified. oldValue: \(arrayValue), newValue: \(arrayPlistValue). test inputs: \(testInputs)", sourceLocation: sourceLocation)
                        }
                    default:
                        Issue.record("key '\(key)' was modified. oldValue: \(String(describing: oldValue)), newValue: \(String(describing: newValue)). test inputs: \(testInputs)", sourceLocation: sourceLocation)
                    }
                }

                // For launch on macOS and for any scheme command on iOS, make sure the additional keys are *not* present, or if they are present, they match whatever was originally passed in and were not modified.
                assertKeyUnmodified("com.apple.security.temporary-exception.files.absolute-path.read-only")
                assertKeyUnmodified("com.apple.security.exception.files.absolute-path.read-only")

                assertKeyUnmodified("com.apple.security.temporary-exception.mach-lookup.global-name")
                assertKeyUnmodified("com.apple.security.exception.mach-lookup.global-name")
            }
        }

        // Perform test above with varying inputs
        for schemeCommand: SchemeCommand in [.launch, .test, .profile] {
            try await performTest(schemeCommand, "macosx")
            try await performTest(schemeCommand, "macosx", additionalEntitlements: [
                "com.apple.security.temporary-exception.files.absolute-path.read-only": "/some/path", // single string value
                "com.apple.security.temporary-exception.mach-lookup.global-name": "com.apple.some-port", // single string value
            ])
            try await performTest(schemeCommand, "macosx", additionalEntitlements: [
                "com.apple.security.temporary-exception.files.absolute-path.read-only": ["/some/path"], // array of strings value
                "com.apple.security.temporary-exception.mach-lookup.global-name": ["com.apple.some-port"], // array of strings value
            ])

            try await performTest(schemeCommand, "iphoneos")
            try await performTest(schemeCommand, "iphoneos", additionalEntitlements: [
                "com.apple.security.exception.files.absolute-path.read-only": ["/some/path"],
                "com.apple.security.exception.mach-lookup.global-name": ["com.apple.some-port"],
            ])
        }
    }
}

@Suite
fileprivate struct ProcessProductProvisioningProfileTaskTests {
    @Test
    func diagnostics() async {
        func checkDiagnostics(_ commandLine: [String], errors: [String] = [], warnings: [String] = [], notes: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) async
        {
            let action = ProcessProductProvisioningProfileTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: Path(""), action: action)
            let executionDelegate = MockExecutionDelegate()
            let outputDelegate = MockTaskOutputDelegate()

            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            #expect(result == .failed, sourceLocation: sourceLocation)
            #expect(outputDelegate.errors == errors.map { "error: \($0)" }, sourceLocation: sourceLocation)
            #expect(outputDelegate.warnings == warnings.map { "warning: \($0)" }, sourceLocation: sourceLocation)
            #expect(outputDelegate.notes == notes.map { "note: \($0)" }, sourceLocation: sourceLocation)
        }

        await checkDiagnostics([], errors: ["no input file specified", "missing required option: -o"])
        await checkDiagnostics(["productPackagingUtility", "foo"], errors: ["missing required option: -o"])
        await checkDiagnostics(["productPackagingUtility", "-o", "bar"], errors: ["no input file specified"])
        await checkDiagnostics(["productPackagingUtility", "foo", "-o"], errors: ["missing argument for option: -o"])
        await checkDiagnostics(["productPackagingUtility", "foo", "-o", "bar", "baz"], errors: ["multiple input paths specified"])
        await checkDiagnostics(["productPackagingUtility", "-bogus", "foo", "-o", "bar"], errors: ["unrecognized argument: -bogus"])
    }

    /// Test that copying a provisioning profile plist works.  Presently this does a straight copy with no validation.
    @Test
    func provisioningProfileBasics() async throws {
        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Set up the input file.
        let input = Path.root.join("foo.mobileprovision")
        let inputStream = OutputByteStream()
        inputStream <<< "{\n"
        inputStream <<< "    AppIDName = \"XC Wildcard\";\n"
        inputStream <<< "    ApplicationIdentifierPrefix = ( F00 );\n"
        inputStream <<< "    Platform = ( iOS );\n"
        inputStream <<< "}\n"
        let inputContents = inputStream.bytes
        try executionDelegate.fs.write(input, contents: inputContents)

        // Define the location of the output file.
        let output = Path.root.join("dst/embedded.mobileprovision")
        try executionDelegate.fs.createDirectory(output.dirname)

        let action = ProcessProductProvisioningProfileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["productPackagingUtility", input.str, "-o", output.str], workingDirectory: .root, outputs: [], action: action, execDescription: "Create Product Package")
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the command succeeded with no errors.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the file was copied, and is the same as the source contents.
        let outputContents = try executionDelegate.fs.read(output)
        #expect(inputContents == outputContents)
    }
}
