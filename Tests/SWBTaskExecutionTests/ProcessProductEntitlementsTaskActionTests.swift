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
import SWBCore
import SWBUtil
import SWBTaskExecution
import SWBMacro
import SWBTestSupport

@Suite
fileprivate struct ProcessProductEntitlementsTaskActionTests {
    @Test(.requireHostOS(.macOS)) // crashes on Linux
    func performTaskAction() async throws {
        let directory = Path("/temp")
        let entitlementsPath = directory.join("foobar.entitlements")
        let entitlements = PropertyListItem.plDict(["key": .plString("value")])

        let fs = PseudoFS()
        try fs.createDirectory(directory, recursive: false)
        try fs.write(entitlementsPath, contents: entitlements.asJSONFragment())


        let startTimestamp = try fs.getFileInfo(entitlementsPath).modificationTimestamp
        #expect(startTimestamp == 3)

        /// Configuration for one test run of the task action.
        ///
        /// - Parameter commandLine: array of passed command line arguments, first one is the programs name
        /// - Parameter expected: the returned status code of the task action that is expected for the given input
        /// - Parameter checkOutput: optional handler to check emitted output
        func testPerformTaskAction(commandLine: [String], expected expectedResult: CommandResult, entitlementsVariant: EntitlementsVariant = .signed, destinationPlatformName: String = "platformname", schemeCommand: SchemeCommand = .launch, buildSettings: ((inout MacroValueAssignmentTable, MacroNamespace) throws -> Void)? = nil, modifications: (() throws -> Void)? = nil, checkOutput: ((MockTaskOutputDelegate) throws -> Void)? = nil) async rethrows {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            try buildSettings?(&table, namespace)
            let scope = MacroEvaluationScope(table: table)

            let action = ProcessProductEntitlementsTaskAction(scope: scope,
                                                              fs: fs,
                                                              entitlements: entitlements,
                                                              entitlementsVariant: entitlementsVariant,
                                                              destinationPlatformName: destinationPlatformName,
                                                              entitlementsFilePath: entitlementsPath)

            try modifications?()

            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: directory, action: action)
            let executionDelegate = MockExecutionDelegate(fs: fs, schemeCommand: schemeCommand)
            let outputDelegate = MockTaskOutputDelegate()

            let statusCode = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(statusCode == expectedResult)
            try checkOutput?(outputDelegate)
        }

        // Empty command line should fail.
        await testPerformTaskAction(commandLine: [], expected: .failed)

        // giving an invalid output path should fail the build
        await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/nonExistingDirectory/foobar.output"], expected: .failed, checkOutput: { output in
            #expect(output.warnings.isEmpty, "No warnings should be emitted")
            #expect(output.errors.count == 1)
            #expect(output.errors.first == "error: could not write entitlements file '/nonExistingDirectory/foobar.output': No such file or directory (2)")
        })

        // Necessary command line arguments passed, entitlements not edited should succeed.
        await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"], expected: .succeeded)

        // Modifying the entitlements during creation of action and execution should fail the build.
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .failed,
                                        modifications: {
            try fs.write(entitlementsPath, contents: ByteString(encodingAsUTF8: "some arbitrary string"))
        },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.count == 1)

            #expect(output.errors.first == "error: Entitlements file \"foobar.entitlements\" was modified during the build, which is not supported. You can disable this error by setting 'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION' to 'YES', however this may cause the built product's code signature or provisioning profile to contain incorrect entitlements.")
        })

        // No error if we opt out
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .succeeded,
                                        buildSettings: { table, namespace in table.push(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION, namespace.parseLiteralString("YES")) },
                                        modifications: { try fs.write(entitlementsPath, contents: ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.isEmpty, "Errors shouldn't be emitted")
            try #require(try fs.read(Path("/temp/foobar.output")) == ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml)))
        })

        // No error if we opt out; modification should be ignored for signed entitlements when ENTITLEMENTS_DESTINATION == __entitlements
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .succeeded,
                                        entitlementsVariant: .signed,
                                        buildSettings: { table, namespace in
            table.push(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION, namespace.parseLiteralString("YES"))
            table.push(BuiltinMacros.ENTITLEMENTS_DESTINATION, namespace.parseLiteralString("__entitlements"))
        },
                                        modifications: { try fs.write(entitlementsPath, contents: ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.isEmpty, "Errors shouldn't be emitted")
            try #require(try fs.read(Path("/temp/foobar.output")) == ByteString(PropertyListItem.plDict(["key": .plString("value")]).asBytes(.xml))) // note this is still the original plist
        })

        // ENTITLEMENTS_DESTINATION == Signature allows the modification
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .succeeded,
                                        entitlementsVariant: .signed,
                                        buildSettings: { table, namespace in
            table.push(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION, namespace.parseLiteralString("YES"))
            table.push(BuiltinMacros.ENTITLEMENTS_DESTINATION, namespace.parseLiteralString("Signature"))
        },
                                        modifications: { try fs.write(entitlementsPath, contents: ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.isEmpty, "Errors shouldn't be emitted")
            try #require(try fs.read(Path("/temp/foobar.output")) == ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) // note this is still the modified plist
        })

        // ...as do simulated entitlements, regardless of destination
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .succeeded,
                                        entitlementsVariant: .simulated,
                                        buildSettings: { table, namespace in
            table.push(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION, namespace.parseLiteralString("YES"))
            table.push(BuiltinMacros.ENTITLEMENTS_DESTINATION, namespace.parseLiteralString("__entitlements"))
        },
                                        modifications: { try fs.write(entitlementsPath, contents: ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.isEmpty, "Errors shouldn't be emitted")
            try #require(try fs.read(Path("/temp/foobar.output")) == ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) // note this is still the modified plist
        })
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .succeeded,
                                        entitlementsVariant: .simulated,
                                        buildSettings: { table, namespace in
            table.push(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION, namespace.parseLiteralString("YES"))
            table.push(BuiltinMacros.ENTITLEMENTS_DESTINATION, namespace.parseLiteralString("Signature"))
        },
                                        modifications: { try fs.write(entitlementsPath, contents: ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.isEmpty, "Errors shouldn't be emitted")
            try #require(try fs.read(Path("/temp/foobar.output")) == ByteString(PropertyListItem.plDict(["key": .plString("value")]).asBytes(.xml))) // note this is still the modified plist
        })

        // ...and finally we also let the modifications through for any other value for ENTITLEMENTS_DESTINATION
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .succeeded,
                                        entitlementsVariant: .simulated,
                                        buildSettings: { table, namespace in
            table.push(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION, namespace.parseLiteralString("YES"))
            table.push(BuiltinMacros.ENTITLEMENTS_DESTINATION, namespace.parseLiteralString(""))
        },
                                        modifications: { try fs.write(entitlementsPath, contents: ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.isEmpty, "Errors shouldn't be emitted")
            try #require(try fs.read(Path("/temp/foobar.output")) == ByteString(PropertyListItem.plDict(["key": .plString("value")]).asBytes(.xml))) // note this is still the modified plist
        })
        try await testPerformTaskAction(commandLine: ["programName", "-entitlements", "-o", "/temp/foobar.output"],
                                        expected: .succeeded,
                                        entitlementsVariant: .signed,
                                        buildSettings: { table, namespace in
            table.push(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION, namespace.parseLiteralString("YES"))
            table.push(BuiltinMacros.ENTITLEMENTS_DESTINATION, namespace.parseLiteralString(""))
        },
                                        modifications: { try fs.write(entitlementsPath, contents: ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) },
                                        checkOutput: { output in
            #expect(output.warnings.isEmpty, "Warnings shouldn't be emitted")
            #expect(output.errors.isEmpty, "Errors shouldn't be emitted")
            try #require(try fs.read(Path("/temp/foobar.output")) == ByteString(PropertyListItem.plDict(["key": .plString("value2")]).asBytes(.xml))) // note this is still the modified plist
        })
    }
}
