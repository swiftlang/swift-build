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
import SWBCore
import SWBTaskExecution
import SWBMacro

@Suite(.requireHostOS(.macOS))
fileprivate struct InfoPlistProcessorTaskTests: CoreBasedTests {
    private func prepareContext(_ context: InfoPlistProcessorTaskActionContext, fs: any FSProxy) throws -> Path {
        let serializer = MsgPackSerializer()
        serializer.serialize(context)
        let path = Path("/context")
        try fs.write(path, contents: serializer.byteString)
        return path
    }

    /// Utility method to create and run the task action on the given plist data and call back to a checker to validate the results.
    private func createAndRunTaskAction(inputPlistData: [String: PropertyListItem], scope: MacroEvaluationScope, platformName: String, sdkName: String? = nil, sdkVariant: String? = nil, productTypeId: String? = nil, sourceLocation: SourceLocation = #_sourceLocation, checkResults: (CommandResult, [String: PropertyListItem], MockTaskOutputDelegate) throws -> Void) async throws {
        let core = try await getCore()

        // Create and write the input plist.
        let inputFilePath = Path("/tmp/input.plist")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())
        try executionDelegate.fs.createDirectory(inputFilePath.dirname)
        try await executionDelegate.fs.writePlist(inputFilePath, .plDict(inputPlistData))

        // Look up the product type.
        var productType: ProductTypeSpec? = nil
        if let productTypeId {
            productType = try core.specRegistry.getSpec(productTypeId, domain: platformName) as ProductTypeSpec
        }

        // Create the task action.
        let outputFilePath = Path("/tmp/output.plist")
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'", sourceLocation: sourceLocation)
        let sdkName = sdkName ?? platformName
        let sdk = try #require(core.sdkRegistry.lookup(sdkName), "invalid SDK name '\(sdkName)'", sourceLocation: sourceLocation)
        let sdkVariant = sdkVariant.map(sdk.variant(for:)) ?? nil
        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: productType, platform: platform, sdk: sdk, sdkVariant: sdkVariant, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, inputFilePath.str, "-o", outputFilePath.str], workingDirectory: inputFilePath.dirname, outputs: [], action: action, execDescription: "Copy Info.plist")

        // Run the task action.
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            try checkResults(result, [:], outputDelegate)
            return
        }

        // Read the output file and pass the results to the checker block.
        let contents = try executionDelegate.fs.read(outputFilePath)
        let plist = try PropertyList.fromBytes(contents.bytes)
        guard case .plDict(let dict) = plist else {
            Issue.record("Output property list is not a dictionary.", sourceLocation: sourceLocation)
            return
        }
        try checkResults(result, dict, outputDelegate)
    }

    @Test
    func diagnostics() async throws {
        let core = try await getCore()

        // Check basic diagnostics.
        func checkDiagnostics(_ commandLine: [String], errors: [String], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            let table = MacroValueAssignmentTable(namespace: namespace)
            let scope = MacroEvaluationScope(table: table)
            let platformName = "macosx"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'", sourceLocation: sourceLocation)
            let sdk = try #require(core.sdkRegistry.lookup(platformName), "invalid SDK name '\(platformName)'", sourceLocation: sourceLocation)
            let executionDelegate = MockExecutionDelegate(core: try await getCore())
            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: sdk, sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Info.plist")
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .failed)
            #expect(outputDelegate.messages == errors.map { "error: \($0)" })
        }

        try await checkDiagnostics([], errors: ["no input file specified"])
        try await checkDiagnostics(["infoPlistUtility", "-format", "openstep", "-format", "xml", "-format", "binary", "-format", "unknown"], errors: ["unrecognized argument to -format: 'unknown' (use 'openstep', 'xml', or 'binary')"])
        try await checkDiagnostics(["infoPlistUtility", "-format"], errors: ["missing argument for -format (use 'openstep', 'xml', or 'binary')"])
        try await checkDiagnostics(["infoPlistUtility", "-genpkginfo", "a", "-genpkginfo", "b"], errors: ["multiple pkginfo paths specified"])
        try await checkDiagnostics(["infoPlistUtility", "-requiredArchitecture", "a", "-requiredArchitecture", "b"], errors: ["multiple -requiredArchitecture specified"])
        try await checkDiagnostics(["infoPlistUtility", "-platform", "a"], errors: ["argument to -platform 'a' differs from platform being targeted 'macosx'"])
        try await checkDiagnostics(["infoPlistUtility", "-platform", "macosx", "-platform", "macosx2"], errors: ["multiple platform names specified"])
        try await checkDiagnostics(["infoPlistUtility", "-resourcerulesfile", "a", "-resourcerulesfile", "b"], errors: ["multiple resource rules files specified"])
        try await checkDiagnostics(["infoPlistUtility", "-o", "a", "-o", "b"], errors: ["multiple output files specified"])
        try await checkDiagnostics(["infoPlistUtility", "input1", "input2"], errors: ["multiple input files specified"])
        try await checkDiagnostics(["infoPlistUtility", "-format", "xml", "-genpkginfo", "foo", "-platform", "macosx", "-enforceminimumos", "-expandbuildsettings", "-resourcerulesfile", "foo", "-additionalcontentfile", "foo2", "-requiredArchitecture", "x86_64", "-o", "output", "input", "-unknown"], errors: ["unrecognized option: -unknown"])

        for missingArgOpt in ["-genpkginfo", "-platform", "-resourcerulesfile", "-additionalcontentfile", "-requiredArchitecture", "-o"] {
            try await checkDiagnostics(["infoPlistUtility", missingArgOpt], errors: ["missing argument for \(missingArgOpt)"])
        }

        // Check diagnostics emitted when trying to merge additional content files.
        func checkAdditionalContentDiagnostics(_ additionalContentFilePaths: [String], errors: [String], sourceLocation: SourceLocation = #_sourceLocation, setup: (any FSProxy) async throws -> Void) async throws {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            let table = MacroValueAssignmentTable(namespace: namespace)
            let scope = MacroEvaluationScope(table: table)

            let platformName = "macosx"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'", sourceLocation: sourceLocation)
            let sdk = try #require(core.sdkRegistry.lookup(platformName), "invalid SDK name '\(platformName)'", sourceLocation: sourceLocation)
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: sdk, sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))

            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleDevelopmentRegion": "en",
                "Integer": 1,
                "Array": [1, 2],
            ])
            try await setup(executionDelegate.fs)

            var commandLine = ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist"]
            for path in additionalContentFilePaths { commandLine.append(contentsOf: ["-additionalcontentfile", path]) }
            commandLine.append(contentsOf: ["-o", "/tmp/output.plist"])
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .failed)
            #expect(outputDelegate.messages == errors.map { "error: \($0)" })
        }

        // Test a missing plist file.
        try await checkAdditionalContentDiagnostics(["/tmp/missing.plist"], errors: ["unable to read additional content file \'/tmp/missing.plist\': No such file or directory (2)"]) { fs in
            // No setup since we're testing a missing file.
        }

        // Test trying to merge incompatible types.
        try await checkAdditionalContentDiagnostics(["/tmp/bad.plist"], errors: ["tried to merge array value for key \'Integer\' onto integer value"]) { fs in
            try await fs.writePlist(Path("/tmp/bad.plist"), [
                "Integer": [1, 2],
            ])
        }
        try await checkAdditionalContentDiagnostics(["/tmp/bad.plist"], errors: ["tried to merge string value for key \'Array\' onto array value"]) { fs in
            try await fs.writePlist(Path("/tmp/bad.plist"), [
                "Array": "string",
            ])
        }
    }

    private func createMockScope(debugDescription: String = #function, _ body: ((MacroNamespace, inout MacroValueAssignmentTable) throws -> Void)? = nil) throws -> MacroEvaluationScope {
        // Create a mock table and scope for the processor to use.
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: debugDescription)
        try namespace.declareStringMacro("PRODUCT_NAME")
        try namespace.declareStringMacro("EXECUTABLE_NAME")
        try namespace.declareStringMacro("PRODUCT_BUNDLE_IDENTIFIER")
        try namespace.declareStringMacro("MACOSX_DEPLOYMENT_TARGET")
        try namespace.declareStringMacro("MAC_OS_X_PRODUCT_BUILD_VERSION")
        try namespace.declareStringMacro("XCODE_VERSION_ACTUAL")
        try namespace.declareStringMacro("XCODE_PRODUCT_BUILD_VERSION")
        try namespace.declareStringMacro("PLATFORM_PRODUCT_BUILD_VERSION")
        try namespace.declareStringMacro("GCC_VERSION")
        try namespace.declareStringMacro("SDK_NAME")
        try namespace.declareStringMacro("SDK_PRODUCT_BUILD_VERSION")
        try namespace.declareStringMacro("MARKETING_VERSION")
        try namespace.declareUserDefinedMacro("VERSION_STRING")
        try namespace.declareBooleanMacro("INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE")
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(try #require(namespace.lookupMacroDeclaration("PRODUCT_NAME") as? StringMacroDeclaration), literal: "TestApp")
        table.push(try #require(namespace.lookupMacroDeclaration("EXECUTABLE_NAME") as? StringMacroDeclaration), literal: "TestApp")
        table.push(try #require(namespace.lookupMacroDeclaration("PRODUCT_BUNDLE_IDENTIFIER") as? StringMacroDeclaration), literal: "com.apple.TestApp")
        table.push(try #require(namespace.lookupMacroDeclaration("MACOSX_DEPLOYMENT_TARGET") as? StringMacroDeclaration), literal: "10.12")
        table.push(try #require(namespace.lookupMacroDeclaration("MAC_OS_X_PRODUCT_BUILD_VERSION") as? StringMacroDeclaration), literal: "15E35")
        table.push(try #require(namespace.lookupMacroDeclaration("DEPLOYMENT_TARGET_SETTING_NAME") as? StringMacroDeclaration), literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(try #require(namespace.lookupMacroDeclaration("XCODE_VERSION_ACTUAL") as? StringMacroDeclaration), literal: "0730")
        table.push(try #require(namespace.lookupMacroDeclaration("XCODE_PRODUCT_BUILD_VERSION") as? StringMacroDeclaration), literal: "7D137")
        table.push(try #require(namespace.lookupMacroDeclaration("PLATFORM_PRODUCT_BUILD_VERSION") as? StringMacroDeclaration), literal: "7D137")
        table.push(try #require(namespace.lookupMacroDeclaration("GCC_VERSION") as? StringMacroDeclaration), literal: "com.apple.compilers.llvm.clang.1_0")
        table.push(try #require(namespace.lookupMacroDeclaration("SDK_NAME") as? StringMacroDeclaration), literal: "macosx10.11")
        table.push(try #require(namespace.lookupMacroDeclaration("SDK_PRODUCT_BUILD_VERSION") as? StringMacroDeclaration), literal: "15A284")
        table.push(try #require(namespace.lookupMacroDeclaration("MARKETING_VERSION") as? StringMacroDeclaration), literal: "9.3")
        table.push(try #require(namespace.lookupMacroDeclaration("VERSION_STRING") as? UserDefinedMacroDeclaration), namespace.parseStringList("Version number: \"$(MARKETING_VERSION)\""))
        table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "1,4 2, 3, 0")
        table.push(try #require(namespace.lookupMacroDeclaration("INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE") as? BooleanMacroDeclaration), literal: true)
        try body?(namespace, &table)
        return MacroEvaluationScope(table: table)
    }

    @Test
    func infoPlistProcessorTask() async throws {
        let core = try await getCore()
        let scope = try createMockScope()
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let sdk = try #require(core.sdkRegistry.lookup(platformName), "invalid SDK name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: sdk, sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-enforceminimumos", "-genpkginfo", "/tmp/PkgInfo", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-additionalcontentfile", "/tmp/newcontent.plist", "-additionalcontentfile", "/tmp/mergecontent.plist", "-additionalcontentfile", "/tmp/required.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")


        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        do {
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleSignature": "FOOZ",
                "CFBundleVersion": "1",
                // "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)", this is commented out to test that -enforceminimumos works
                "NSMainNibFile": "MainMenu",
                "NSPrincipalClass": "NSApplication",
                "CFBundleResourceSpecification": "",                // To test eliding empty string values
                "DoNotElide": "",                                   // To test *not* eliding empty string values which are not among keys we should elide
                "AsideBundleIdentifier": "$(CFBundleIdentifier)",   // To test evaluating $(CFBundleIdentifier)
                "TestVersionString": "$(VERSION_STRING)",           // To test that quotes are preserved when evaluating a user-defined macro in string form

                // Content that will get merged with content from the additional content files.
                "IntToInt": 1,
                "IntToString": 2,
                "MergeArray": [1, 2],
                "MergeDict": ["one": "one", "two": "two"],
                "UIRequiredDeviceCapabilities": ["arm64"],
            ])
        }
        do {
            try await executionDelegate.fs.writePlist(Path("/tmp/newcontent.plist"), [
                "Integer": 1,
                "String": "string",
                "Array": [1, 2],
                "Dict": [
                    "one": "one",
                    "two": "two",
                ],
            ])
        }
        do {
            try await executionDelegate.fs.writePlist(Path("/tmp/mergecontent.plist"), [
                "IntToInt": 5,
                "IntToString": "string",
                "MergeArray": [1, 4],
                "MergeDict": [
                    "two": "three",
                    "four": "four",
                ],
            ])
        }
        do {
            // This will cause the array form in the base Info.plist to be promoted to a dictionary.
            try await executionDelegate.fs.writePlist(Path("/tmp/required.plist"), [
                "UIRequiredDeviceCapabilities": [
                    "armv7": true,
                ],
            ])
        }

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            // Check the core values in the property list.
            #expect(dict["CFBundleDevelopmentRegion"]?.stringValue == "en")
            #expect(dict["CFBundleExecutable"]?.stringValue == "TestApp")
            #expect(dict["CFBundleIdentifier"]?.stringValue == "com.apple.TestApp")
            #expect(dict["CFBundleName"]?.stringValue == "TestApp")

            // Check that enforcing the minimum OS version worked
            #expect(dict["LSMinimumSystemVersion"]?.stringValue == "10.12")

            // Check that values we expected to be elided were, and ones we didn't were not.
            #expect(dict["CFBundleResourceSpecification"] == nil)
            #expect(dict["DoNotElide"]?.stringValue == "")

            // Check that $(CFBundleIdentifier) was evaluated.
            #expect(dict["AsideBundleIdentifier"]?.stringValue == "com.apple.TestApp")

            // Check that the TestVersionString ends up with the expected value.
            #expect(dict["TestVersionString"]?.stringValue == "Version number: \"9.3\"")

            // Check the values we expect to get from the 'macosx' platform which we passed on the command line.
            if let supportedPlatformsArray = dict["CFBundleSupportedPlatforms"]?.arrayValue {
                let supportedPlatforms = supportedPlatformsArray.map { $0.stringValue }
                #expect(supportedPlatforms == ["MacOSX"])
            }
            else {
                Issue.record("CFBundleSupportedPlatforms is not an array.")
            }
            #expect(dict["BuildMachineOSBuild"]?.stringValue == "15E35")
            #expect(dict["DTXcode"]?.stringValue == "0730")
            #expect(dict["DTXcodeBuild"]?.stringValue == "7D137")
            #expect(dict["DTPlatformBuild"]?.stringValue == "7D137")
            #expect(dict["DTCompiler"]?.stringValue == "com.apple.compilers.llvm.clang.1_0")
            #expect(dict["DTSDKName"]?.stringValue == "macosx10.11")
            #expect(dict["DTSDKBuild"]?.stringValue == "15A284")
            #expect(dict["UIDeviceFamily"] == nil, "unexpected device family: \(String(describing: dict["UIDeviceFamily"]))")

            // Check that the contents from 'newcontent.plist' is present.
            #expect(dict["Integer"]?.intValue == 1)
            #expect(dict["String"]?.stringValue == "string")
            #expect(dict["Array"]?.arrayValue ?? [] == [.plInt(1), .plInt(2)])
            #expect(dict["Dict"]?.dictValue ?? [:] == ["one": .plString("one"), "two": .plString("two")])

            // Check that we properly merged the content from 'mergecontent.plist'.
            #expect(dict["IntToInt"]?.intValue == 5)
            #expect(dict["IntToString"]?.stringValue == "string")
            #expect(dict["MergeArray"]?.arrayValue ?? [] == [.plInt(1), .plInt(2), .plInt(4)])
            #expect(dict["MergeDict"]?.dictValue ?? [:] == ["one": .plString("one"), "two": .plString("three"), "four": .plString("four")])

            // Check that we properly promoted and merged the required device capabilities.
            #expect(dict["UIRequiredDeviceCapabilities"]?.dictValue ?? [:] == ["arm64": .plBool(true), "armv7": .plBool(true)])

            let pkgInfoContents = try executionDelegate.fs.read(Path("/tmp/PkgInfo"))
            #expect(pkgInfoContents == ByteString(encodingAsUTF8: "APPLFOOZ"))
        }
    }

    /// Test behaviors specific to merging the content from the `AdditionalInfo` dictionary in the platform's Info.plist into the final Info.plist.
    @Test
    func mergingPlatformAdditionalInfo() async throws {
        let core = try await getCore()

        // Test the macOS AdditionalInfo dictionary.
        do {
            let scope = try createMockScope(debugDescription: "\(#function)_macOS") { namespace, table in
                try namespace.declareStringMacro("MINIMUM_SYSTEM_VERSION")
                table.push(try #require(namespace.lookupMacroDeclaration("MINIMUM_SYSTEM_VERSION") as? StringMacroDeclaration), literal: "10.14.4")
            }
            let platformName = "macosx"
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: core.platformRegistry.lookup(name: platformName), sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-enforceminimumos", "-genpkginfo", "/tmp/PkgInfo", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

            // Write the test files.
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleSignature": "FOOZ",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "$(MINIMUM_SYSTEM_VERSION)",      // To check that the value of this key from the platform does not replace this value.
                "NSMainNibFile": "MainMenu",
                "NSPrincipalClass": "NSApplication",
            ])

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            guard result == .succeeded else {
                Issue.record("task failed; errors: \(outputDelegate.errors)")
                return
            }

            // Check the output.
            do {
                // Read the output property list.
                let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
                let plist = try PropertyList.fromBytes(contents.bytes)
                guard case .plDict(let dict) = plist else {
                    Issue.record("Output property list is not a dictionary.")
                    return
                }

                // Check that some expected values from the platform are present.
                #expect(dict["BuildMachineOSBuild"]?.stringValue == "15E35")
                if let supportedPlatformsArray = dict["CFBundleSupportedPlatforms"]?.arrayValue {
                    let supportedPlatforms = supportedPlatformsArray.map { $0.stringValue }
                    #expect(supportedPlatforms == ["MacOSX"])
                }
                else {
                    Issue.record("CFBundleSupportedPlatforms is not an array.")
                }
                #expect(dict["DTCompiler"]?.stringValue == "com.apple.compilers.llvm.clang.1_0")
                #expect(dict["DTPlatformBuild"]?.stringValue == "7D137")
                #expect(dict["DTPlatformName"]?.stringValue == "macosx")
                // Skip DTPlatformVersion since we can't control for its value in this test.
                #expect(dict["DTSDKBuild"]?.stringValue == "15A284")
                #expect(dict["DTSDKName"]?.stringValue == "macosx10.11")
                #expect(dict["DTXcode"]?.stringValue == "0730")
                #expect(dict["DTXcodeBuild"]?.stringValue == "7D137")

                // Check that LSMinimumSystemVersion did *not* come from the platform.  Xcode.app expects this behavior; see <rdar://problem/55196427>.
                #expect(dict["LSMinimumSystemVersion"]?.stringValue == "10.14.4")
            }
        }
    }

    /// Validates the `INFOPLIST_FILE_CONTENTS` build setting is applied on top of the Info.plist loaded from disk.
    @Test
    func infoPlistFileContentsBuildSetting() async throws {
        let plistData: [String: PropertyListItem] = [
            "Key1": "ExistingValue1",
            "Key2": "ExistingValue2",
        ]

        let INFOPLIST_FILE_CONTENTS = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
            <dict>
                <key>Key2</key><string>NewValue2</string>
                <key>Key3</key><string>NewValue3</string>
            </dict>
        </plist>
        """

        // Test building for iOS.
        do {
            let scope = try createMockScope(debugDescription: "\(#function)_iOS") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
                table.push(try #require(namespace.lookupMacroDeclaration("INFOPLIST_FILE_CONTENTS") as? StringMacroDeclaration), literal: INFOPLIST_FILE_CONTENTS)
            }

            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "iphoneos") { result, dict, outputDelegate in
                // Check preexisting key is still present
                #expect(dict["Key1"]?.stringValue == "ExistingValue1")
                // Check preexisting key has been replaced
                #expect(dict["Key2"]?.stringValue == "NewValue2")
                // Check new key was added
                #expect(dict["Key3"]?.stringValue == "NewValue3")
            }
        }
    }

    func testScenario(platformName: String, sdkName: String? = nil, sdkVariant: String = "", deploymentTargetName: String, deploymentTarget: String, minimumSystemVersion: String, sourceLocation: SourceLocation = #_sourceLocation, checkResults: ([String: PropertyListItem], String, MockTaskOutputDelegate) -> Void) async throws {
        let minimumSystemVersionKey: String
        switch platformName {
        case "driverkit":
            minimumSystemVersionKey = "OSMinimumDriverKitVersion"
        case "macosx":
            minimumSystemVersionKey = "LSMinimumSystemVersion"
        default:
            minimumSystemVersionKey = "MinimumOSVersion"
        }
        let plistData: [String: PropertyListItem] = [
            minimumSystemVersionKey: .plString(minimumSystemVersion),
        ]
        let scope = try createMockScope(debugDescription: "\(#function)_\(platformName)") { namespace, table in
            let sdkName = sdkName ?? platformName
            table.push(try #require(namespace.lookupMacroDeclaration("SDKROOT") as? PathMacroDeclaration), literal: sdkName)
            table.push(try #require(namespace.lookupMacroDeclaration("SDK_NAME") as? StringMacroDeclaration), literal: "")                         // This is wrong but we don't have a good way to override this with the real version
            table.push(try #require(namespace.lookupMacroDeclaration("SDK_VARIANT") as? StringMacroDeclaration), literal: sdkVariant)
            table.push(try #require(namespace.lookupMacroDeclaration("DEPLOYMENT_TARGET_SETTING_NAME") as? StringMacroDeclaration), literal: deploymentTargetName)
            table.push(try #require(namespace.lookupMacroDeclaration(deploymentTargetName) as? StringMacroDeclaration), literal: deploymentTarget)
            // I'm not sure why createMockScope() includes a particular and strange value for TARGET_DEVICE_FAMILY, but we override it here.
            if sdkVariant == MacCatalystInfo.sdkVariantName {
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "6")      // 6 is Mac
            }
            else {
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "")
            }
        }
        try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: platformName, sdkName: sdkName, sdkVariant: sdkVariant, productTypeId: "com.apple.product-type.framework") { result, dict, outputDelegate in
            #expect(result == (outputDelegate.errors.isEmpty ? .succeeded : .failed), sourceLocation: sourceLocation)
            checkResults(dict, deploymentTargetName, outputDelegate)
        }
    }

    /// Test that the processor correctly identifies invalid values for the minimum system version Info.plist key across a variety of scenarios and acts accordingly.
    @Test(.requireSDKs(.macOS))
    func minimumSystemVersionValidation_macOS() async throws {
        // macOS
        try await testScenario(platformName: "macosx", deploymentTargetName: "MACOSX_DEPLOYMENT_TARGET", deploymentTarget: "11.0", minimumSystemVersion: "10.15") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"]?.stringValue == "11.0")
            #expect(dict["MinimumOSVersion"] == nil)

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == ["warning: LSMinimumSystemVersion of \'10.15\' is less than the value of \(deploymentTargetName) \'11.0\' - setting to \'11.0\'."])
            #expect(outputDelegate.notes == [])
        }

        // MacCatalyst
        try await testScenario(platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, deploymentTargetName: "MACOSX_DEPLOYMENT_TARGET", deploymentTarget: "11.0", minimumSystemVersion: "10.15") { dict, deploymentTargetName, outputDelegate in
            // Catalyst uses the macOS key.  c.f. <rdar://problem/39179904>
            #expect(dict["LSMinimumSystemVersion"]?.stringValue == "11.0")
            #expect(dict["MinimumOSVersion"] == nil)

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == ["warning: LSMinimumSystemVersion of \'10.15\' is less than the value of \(deploymentTargetName) \'11.0\' - setting to \'11.0\'."])
            #expect(outputDelegate.notes == [])
        }

        // Empty deployment target
        try await testScenario(platformName: "macosx", deploymentTargetName: "MACOSX_DEPLOYMENT_TARGET", deploymentTarget: "", minimumSystemVersion: "10.15") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"]?.stringValue == "10.15")
            #expect(dict["MinimumOSVersion"] == nil)

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])
        }

        // Empty minimum system version - we replace it with the deployment target
        try await testScenario(platformName: "macosx", deploymentTargetName: "MACOSX_DEPLOYMENT_TARGET", deploymentTarget: "11.0", minimumSystemVersion: "") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"]?.stringValue == "11.0")
            #expect(dict["MinimumOSVersion"] == nil)

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == ["warning: LSMinimumSystemVersion is explicitly set to empty - setting to value of \(deploymentTargetName) \'11.0\'."])
            #expect(outputDelegate.notes == [])
        }

        // Invalid minimum system version - we emit an error but don't change the value.
        try await testScenario(platformName: "macosx", deploymentTargetName: "MACOSX_DEPLOYMENT_TARGET", deploymentTarget: "11.0", minimumSystemVersion: "nuts") { dict, deploymentTargetName, outputDelegate in
            // We should have added some keys.
            #expect(dict["LSMinimumSystemVersion"] == nil)
            #expect(dict["MinimumOSVersion"] == nil)

            #expect(outputDelegate.errors == ["error: LSMinimumSystemVersion \'nuts\' is not a valid version."])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])
        }
    }

    /// Test that the processor correctly identifies invalid values for the minimum system version Info.plist key across a variety of scenarios and acts accordingly.
    @Test(.requireSDKs(.iOS))
    func minimumSystemVersionValidation_iOS() async throws {
        // iOS
        try await testScenario(platformName: "iphoneos", deploymentTargetName: "IPHONEOS_DEPLOYMENT_TARGET", deploymentTarget: "14.0", minimumSystemVersion: "13.0") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"] == nil)
            #expect(dict["MinimumOSVersion"]?.stringValue == "14.0")

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == ["warning: MinimumOSVersion of \'13.0\' is less than the value of \(deploymentTargetName) \'14.0\' - setting to \'14.0\'."])
            #expect(outputDelegate.notes == [])
        }

        // Empty deployment target
        try await testScenario(platformName: "iphoneos", deploymentTargetName: "IPHONEOS_DEPLOYMENT_TARGET", deploymentTarget: "", minimumSystemVersion: "13.0") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"] == nil)
            #expect(dict["MinimumOSVersion"]?.stringValue == "13.0")

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])
        }

        // Empty minimum system version - we replace it with the deployment target
        try await testScenario(platformName: "iphoneos", deploymentTargetName: "IPHONEOS_DEPLOYMENT_TARGET", deploymentTarget: "14.0", minimumSystemVersion: "") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"] == nil)
            #expect(dict["MinimumOSVersion"]?.stringValue == "14.0")

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == ["warning: MinimumOSVersion is explicitly set to empty - setting to value of \(deploymentTargetName) \'14.0\'."])
            #expect(outputDelegate.notes == [])
        }

        // Invalid minimum system version - we emit an error but don't change the value.
        try await testScenario(platformName: "iphoneos", deploymentTargetName: "IPHONEOS_DEPLOYMENT_TARGET", deploymentTarget: "14.0", minimumSystemVersion: "nuts") { dict, deploymentTargetName, outputDelegate in
            // We should have added some keys.
            #expect(dict["LSMinimumSystemVersion"] == nil)
            #expect(dict["MinimumOSVersion"] == nil)

            #expect(outputDelegate.errors == ["error: MinimumOSVersion \'nuts\' is not a valid version."])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])
        }
    }

    /// Test that the processor correctly identifies invalid values for the minimum system version Info.plist key across a variety of scenarios and acts accordingly.
    @Test(.requireSDKs(.tvOS))
    func minimumSystemVersionValidation_tvOS() async throws {
        try await testScenario(platformName: "appletvos", deploymentTargetName: "TVOS_DEPLOYMENT_TARGET", deploymentTarget: "14.0", minimumSystemVersion: "13.0") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"] == nil)
            #expect(dict["MinimumOSVersion"]?.stringValue == "14.0")

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == ["warning: MinimumOSVersion of \'13.0\' is less than the value of \(deploymentTargetName) \'14.0\' - setting to \'14.0\'."])
            #expect(outputDelegate.notes == [])
        }
    }

    /// Test that the processor correctly identifies invalid values for the minimum system version Info.plist key across a variety of scenarios and acts accordingly.
    @Test(.requireSDKs(.driverKit))
    func minimumSystemVersionValidation_DriverKit() async throws {
        try await testScenario(platformName: "driverkit", sdkName: "driverkit", deploymentTargetName: "DRIVERKIT_DEPLOYMENT_TARGET", deploymentTarget: "20.0", minimumSystemVersion: "19.0") { dict, deploymentTargetName, outputDelegate in
            #expect(dict["LSMinimumSystemVersion"] == nil)
            #expect(dict["MinimumOSVersion"] == nil)
            #expect(dict["OSMinimumDriverKitVersion"]?.stringValue == "20.0")

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == ["warning: OSMinimumDriverKitVersion of \'19.0\' is less than the value of \(deploymentTargetName) \'20.0\' - setting to \'20.0\'."])
            #expect(outputDelegate.notes == [])
        }
    }

    /// When processing an Info.plist configured to build for both macCatalyst and iOS, the results will be different depending on whether we're building for macCatalyst or for iOS.
    @Test
    func processingInfoPlistConfiguredForBothMacCatalystAndIOS() async throws {
        let services: [[String: PropertyListItem]] = [
            [
                "NSMenuItem": [
                    "default": "Stuff",
                ],
                "NSMessage": "This doesn't work",
            ],
            [
                "NSMenuItem": [
                    "default": "More",
                ],
                "NSMessage": "This one does",
            ],
        ]
        let plistData: [String: PropertyListItem] = [
            "Foo": "Bar",
            "LSApplicationCategoryType": "public.app-category.entertainment",
            "LSRequiresIPhoneOS": true,
            "NSSupportsAutomaticTermination": true,
            "NSSupportsSuddenTermination": false,
            "NSServices": PropertyListItem(services),
        ]

        // Test building for iOS.
        do {
            let scope = try createMockScope(debugDescription: "\(#function)_iOS") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
            }

            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "iphoneos") { result, dict, outputDelegate in
                // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
                #expect(dict["Foo"]?.stringValue ?? "" == "Bar")

                // Check that iOS-specific keys are present.
                #expect(dict["LSRequiresIPhoneOS"]?.boolValue == true)
                #expect(dict["LSApplicationCategoryType"]?.stringValue == "public.app-category.entertainment")

                // Check that macOS-specific keys have been removed.
                #expect(dict["NSSupportsAutomaticTermination"] == nil)
                #expect(dict["NSSupportsSuddenTermination"] == nil)
                #expect(dict["NSServices"] == nil)

                // Check that there were no issues.
                #expect(outputDelegate.errors == [])
                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.notes == [])

                // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
                let output = outputDelegate.textBytes.asString.split(separator: "\n")
                #expect(output.contains("removing entry for \"NSSupportsAutomaticTermination\" - only supported on macOS"))
                #expect(output.contains("removing entry for \"NSSupportsSuddenTermination\" - only supported on macOS"))
            }
        }

        // Test build for macCatalyst.
        do {
            let scope = try createMockScope(debugDescription: "\(#function)_macOS") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("SDK_VARIANT") as? StringMacroDeclaration), literal: MacCatalystInfo.sdkVariantName)
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
            }

            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName) { result, dict, outputDelegate in
                // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
                #expect(dict["Foo"]?.stringValue ?? "" == "Bar")
                #expect(dict["LSApplicationCategoryType"]?.stringValue == "public.app-category.entertainment")


                // Check that macOS-specific keys are present.
                #expect(dict["NSSupportsAutomaticTermination"]?.boolValue == true)
                #expect(dict["NSSupportsSuddenTermination"]?.boolValue == false)
                #expect(dict["NSServices"]?.arrayValue == services.map { $0.propertyListItem })

                // Check that iOS-specific keys have been removed.
                #expect(dict["LSRequiresIPhoneOS"] == nil)

                // Check that there were no issues.
                #expect(outputDelegate.errors == [])
                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.notes == [])

                // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
                let output = outputDelegate.textBytes.asString.split(separator: "\n")
                #expect(output.contains("removing entry for \"LSRequiresIPhoneOS\" - not supported on macOS"))
            }
        }
    }

    /// When processing an Info.plist for macCatalyst, make sure expected keys get added or transformed.
    @Test
    func processingInfoPlistForMacCatalyst() async throws {
        do {
            let plistData: [String: PropertyListItem] = [
                "Foo": "Bar",
            ]
            let scope = try createMockScope(debugDescription: "\(#function)_app_macCatalyst_missing") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("SDK_VARIANT") as? StringMacroDeclaration), literal: MacCatalystInfo.sdkVariantName)
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
            }
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, productTypeId: "com.apple.product-type.application") { result, dict, outputDelegate in
                // We should have added some keys.
                #expect(dict["Foo"]?.stringValue ?? "" == "Bar")
                #expect(dict["NSSupportsAutomaticTermination"]?.boolValue ?? false)
                #expect(dict["NSSupportsSuddenTermination"]?.boolValue ?? false)

                // Check that there were no issues.
                #expect(outputDelegate.errors == [])
                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.notes == [])

                // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
                let output = outputDelegate.textBytes.asString.split(separator: "\n")
                #expect(output.contains("adding entry for \"NSSupportsAutomaticTermination\" => 1"))
                #expect(output.contains("adding entry for \"NSSupportsSuddenTermination\" => 1"))
            }
        }

        // Test that keys are not added (overwritten) when already present when building an application for macCatalyst.
        do {
            let plistData: [String: PropertyListItem] = [
                "Foo": "Bar",
                "NSSupportsAutomaticTermination": false,
                "NSSupportsSuddenTermination": false,
            ]
            let scope = try createMockScope(debugDescription: "\(#function)_app_macCatalyst_present") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("SDK_VARIANT") as? StringMacroDeclaration), literal: MacCatalystInfo.sdkVariantName)
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
            }
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, productTypeId: "com.apple.product-type.application") { result, dict, outputDelegate in
                // We should have added some keys.
                #expect(dict["Foo"]?.stringValue == "Bar")
                if let autoTerm = dict["NSSupportsAutomaticTermination"]?.boolValue {
                    #expect(!autoTerm)
                }
                else {
                    Issue.record("NSSupportsAutomaticTermination not found")
                }
                if let suddenTerm = dict["NSSupportsSuddenTermination"]?.boolValue {
                    #expect(!suddenTerm)
                }
                else {
                    Issue.record("NSSupportsSuddenTermination not found")
                }

                // Check that there were no issues.
                #expect(outputDelegate.errors == [])
                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.notes == [])

                // Check expected content in the output stream.
                let output = outputDelegate.textBytes.asString
                #expect(output == "")
            }
        }

        // Test that keys are not added if absent when building a non-application for macCatalyst.
        do {
            let plistData: [String: PropertyListItem] = [
                "Foo": "Bar",
            ]
            let scope = try createMockScope(debugDescription: "\(#function)_nonapp_macCatalyst_present") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("SDK_VARIANT") as? StringMacroDeclaration), literal: MacCatalystInfo.sdkVariantName)
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
            }
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, productTypeId: nil) { result, dict, outputDelegate in
                // We should have added some keys.
                #expect(dict["Foo"]?.stringValue == "Bar")
                #expect(dict["NSSupportsAutomaticTermination"] == nil)
                #expect(dict["NSSupportsSuddenTermination"] == nil)

                // Check that there were no issues.
                #expect(outputDelegate.errors == [])
                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.notes == [])

                // Check expected content in the output stream.
                let output = outputDelegate.textBytes.asString
                #expect(output == "")
            }
        }

        // Test that keys are not added if absent when building an application for iOS.
        do {
            let plistData: [String: PropertyListItem] = [
                "Foo": "Bar",
            ]
            let scope = try createMockScope(debugDescription: "\(#function)_app_ios_missing") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("SDK_VARIANT") as? StringMacroDeclaration), literal: MacCatalystInfo.sdkVariantName)
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
            }
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "iphoneos", productTypeId: "com.apple.product-type.application") { result, dict, outputDelegate in
                // We should have added some keys.
                #expect(dict["Foo"]?.stringValue ?? "" == "Bar")
                #expect(dict["NSSupportsAutomaticTermination"] == nil)
                #expect(dict["NSSupportsSuddenTermination"] == nil)

                // Check that there were no issues.
                #expect(outputDelegate.errors == [])
                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.notes == [])

                // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
                let output = outputDelegate.textBytes.asString
                #expect(output == "")
            }
        }

        // Test that keys are not added if absent when building an application for macOS (not macCatalyst).
        do {
            let plistData: [String: PropertyListItem] = [
                "Foo": "Bar",
            ]
            let scope = try createMockScope(debugDescription: "\(#function)_app_ios_missing") { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
            }
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", productTypeId: "com.apple.product-type.application") { result, dict, outputDelegate in
                // We should have added some keys.
                #expect(dict["Foo"]?.stringValue ?? "" == "Bar")
                #expect(dict["NSSupportsAutomaticTermination"] == nil)
                #expect(dict["NSSupportsSuddenTermination"] == nil)

                // Check that there were no issues.
                #expect(outputDelegate.errors == [])
                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.notes == [])

                // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
                let output = outputDelegate.textBytes.asString
                #expect(output == "")
            }
        }
    }

    /// Common Info.plist input data for the various per-platform tests below.
    private let commonProcessingInfoPlistData: [String: PropertyListItem] = [
        "Foo": "Bar",
        "LSApplicationCategoryType": "public.app-category.entertainment",
        "LSRequiresIPhoneOS": true,
        "UIBackgroundModes": [
            "audio",
            "location",
            "voip",
            "fetch",
            "remote-notification",
            "newsstand-content",
            "external-accessory",
            "bluetooth-central",
            "bluetooth-peripheral",
            "network-authentication",
            "nearby-interaction",
            "processing",
            "push-to-talk",
        ]
    ]

    /// When processing an Info.plist configured to build for iOS.
    @Test(.requireSDKs(.iOS))
    func processingInfoPlistConfiguredForPlatform_iOS() async throws {
        let scope = try createMockScope(debugDescription: "\(#function)_iOS") { namespace, table in
            table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
        }

        try await createAndRunTaskAction(inputPlistData: commonProcessingInfoPlistData, scope: scope, platformName: "iphoneos") { result, dict, outputDelegate in
            // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
            #expect(dict["Foo"]?.stringValue ?? "" == "Bar")

            // Check that iOS-specific keys are present.
            #expect(dict["LSRequiresIPhoneOS"]?.boolValue == true)

            // Check that only the iOS-specific values exist.
            let backgroundModes = try #require(dict["UIBackgroundModes"]?.stringArrayValue)
            #expect(backgroundModes.contains("audio"))
            #expect(backgroundModes.contains("location"))
            #expect(backgroundModes.contains("voip"))
            #expect(backgroundModes.contains("fetch"))
            #expect(backgroundModes.contains("remote-notification"))
            #expect(backgroundModes.contains("newsstand-content"))
            #expect(backgroundModes.contains("external-accessory"))
            #expect(backgroundModes.contains("bluetooth-central"))
            #expect(backgroundModes.contains("bluetooth-peripheral"))
            #expect(backgroundModes.contains("network-authentication"))
            #expect(backgroundModes.contains("nearby-interaction"))
            #expect(backgroundModes.contains("processing"))
            #expect(backgroundModes.contains("push-to-talk"))

            // Check that there were no issues.
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])

            // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
            let output = outputDelegate.textBytes.asString
            #expect(output.isEmpty)
        }
    }

    /// When processing an Info.plist configured to build for tvOS.
    @Test(.requireSDKs(.tvOS))
    func processingInfoPlistConfiguredForPlatform_tvOS() async throws {
        let scope = try createMockScope(debugDescription: "\(#function)_tvOS") { namespace, table in
            table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "3")
        }

        try await createAndRunTaskAction(inputPlistData: commonProcessingInfoPlistData, scope: scope, platformName: "appletvos") { result, dict, outputDelegate in
            // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
            #expect(dict["Foo"]?.stringValue ?? "" == "Bar")

            // This key applies to both iOS and tvOS.
            #expect(dict["LSRequiresIPhoneOS"]?.boolValue == true)

            // Check that only the tvOS-specific values exist.
            let backgroundModes = try #require(dict["UIBackgroundModes"]?.stringArrayValue)
            #expect(backgroundModes.contains("audio"))
            #expect(!backgroundModes.contains("location"))
            #expect(!backgroundModes.contains("voip"))
            #expect(backgroundModes.contains("fetch"))
            #expect(backgroundModes.contains("remote-notification"))
            #expect(!backgroundModes.contains("newsstand-content"))
            #expect(!backgroundModes.contains("external-accessory"))
            #expect(!backgroundModes.contains("bluetooth-central"))
            #expect(!backgroundModes.contains("bluetooth-peripheral"))
            #expect(!backgroundModes.contains("network-authentication"))
            #expect(!backgroundModes.contains("nearby-interaction"))
            #expect(backgroundModes.contains("processing"))
            #expect(!backgroundModes.contains("push-to-talk"))

            // Check that there were no issues.
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])

            // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
            let output = outputDelegate.textBytes.asString
            XCTAssertMatch(output, .contains("removing value \"bluetooth-central\" for \"UIBackgroundModes\" - not supported on tvOS"))
            XCTAssertMatch(output, .contains("removing value \"bluetooth-peripheral\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"external-accessory\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"location\" for \"UIBackgroundModes\" - not supported on tvOS"))
            XCTAssertMatch(output, .contains("removing value \"network-authentication\" for \"UIBackgroundModes\" - not supported on tvOS"))
            XCTAssertMatch(output, .contains("removing value \"nearby-interaction\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"newsstand-content\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"push-to-talk\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"voip\" for \"UIBackgroundModes\" - not supported on tvOS"))
        }
    }

    /// When processing an Info.plist configured to build for visionOS.
    @Test(.requireSDKs(.xrOS))
    func processingInfoPlistConfiguredForPlatform_visionOS() async throws {
        let scope = try createMockScope(debugDescription: "\(#function)_visionOS") { namespace, table in
            table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "7")
        }

        try await createAndRunTaskAction(inputPlistData: commonProcessingInfoPlistData, scope: scope, platformName: "xros") { result, dict, outputDelegate in
            // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
            #expect(dict["Foo"]?.stringValue ?? "" == "Bar")

            // Check that macOS-specific keys are not present.
            #expect(dict["LSApplicationCategoryType"] == nil)

            // This key applies to iOS, tvOS, and visionOS.
            #expect(dict["LSRequiresIPhoneOS"]?.boolValue == true)

            // Check that only the visionOS-specific values exist.
            let backgroundModes = try #require(dict["UIBackgroundModes"]?.stringArrayValue)
            #expect(backgroundModes.contains("audio"))
            #expect(!backgroundModes.contains("location"))
            #expect(backgroundModes.contains("voip"))
            #expect(backgroundModes.contains("fetch"))
            #expect(backgroundModes.contains("remote-notification"))
            #expect(!backgroundModes.contains("newsstand-content"))
            #expect(!backgroundModes.contains("external-accessory"))
            #expect(backgroundModes.contains("bluetooth-central"))
            #expect(!backgroundModes.contains("bluetooth-peripheral"))
            #expect(backgroundModes.contains("network-authentication"))
            #expect(!backgroundModes.contains("nearby-interaction"))
            #expect(backgroundModes.contains("processing"))
            #expect(!backgroundModes.contains("push-to-talk"))

            // Check that there were no issues.
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])

            // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
            let output = outputDelegate.textBytes.asString
            XCTAssertMatch(output, .contains("removing entry for \"LSApplicationCategoryType\" - not supported on visionOS"))
            XCTAssertMatch(output, .contains("removing value \"bluetooth-peripheral\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"external-accessory\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"location\" for \"UIBackgroundModes\" - not supported on visionOS"))
            XCTAssertMatch(output, .contains("removing value \"nearby-interaction\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"newsstand-content\" for \"UIBackgroundModes\" - only supported on iOS"))
            XCTAssertMatch(output, .contains("removing value \"push-to-talk\" for \"UIBackgroundModes\" - only supported on iOS"))
        }
    }

    /// When processing an Info.plist configured to build for macOS.
    @Test(.requireSDKs(.macOS))
    func processingInfoPlistConfiguredForPlatform_macOS() async throws {
        let scope = try createMockScope(debugDescription: "\(#function)_macOS") { namespace, table in
            // no-op
        }

        try await createAndRunTaskAction(inputPlistData: commonProcessingInfoPlistData, scope: scope, platformName: "macosx") { result, dict, outputDelegate in
            // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
            #expect(dict["Foo"]?.stringValue ?? "" == "Bar")

            // Check that iOS-specific keys are not present.
            #expect(dict["LSRequiresIPhoneOS"] == nil)

            // Check that only the macOS-specific values exist.
            #expect(dict["UIBackgroundModes"]?.stringArrayValue == [])

            // Check that there were no issues.
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])
        }
    }

    /// When processing an Info.plist configured to build for Mac Catalyst
    /// - remark:I think this is testing common processing behavior in the context of Catalyst, rather than the specialized tests in `testProcessingInfoPlistForMacCatalyst()` above.
    @Test(.requireSDKs(.macOS))
    func processingInfoPlistConfiguredForPlatform_MacCatalyst() async throws {
        let scope = try createMockScope(debugDescription: "\(#function)_MacCatalyst") { namespace, table in
            table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
        }

        try await createAndRunTaskAction(inputPlistData: commonProcessingInfoPlistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName) { result, dict, outputDelegate in
            // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
            #expect(dict["Foo"]?.stringValue ?? "" == "Bar")

            // Check that iOS-specific keys are not present.
            #expect(dict["LSRequiresIPhoneOS"] == nil)

            // Check that only the iOS-specific values exist.
            let backgroundModes = try #require(dict["UIBackgroundModes"]?.stringArrayValue)
            #expect(backgroundModes.contains("audio"))
            #expect(backgroundModes.contains("location"))
            #expect(backgroundModes.contains("voip"))
            #expect(backgroundModes.contains("fetch"))
            #expect(backgroundModes.contains("remote-notification"))
            #expect(backgroundModes.contains("newsstand-content"))
            #expect(backgroundModes.contains("external-accessory"))
            #expect(backgroundModes.contains("bluetooth-central"))
            #expect(backgroundModes.contains("bluetooth-peripheral"))
            #expect(backgroundModes.contains("network-authentication"))
            #expect(backgroundModes.contains("nearby-interaction"))
            #expect(backgroundModes.contains("processing"))
            #expect(backgroundModes.contains("push-to-talk"))

            // Check that there were no issues.
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])
        }
    }

    /// When processing an Info.plist configured to build for watchOS.
    @Test(.requireSDKs(.watchOS))
    func processingInfoPlistConfiguredForPlatform_watchOS() async throws {
        let scope = try createMockScope(debugDescription: "\(#function)_watchOS") { namespace, table in
            table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "5")
        }

        try await createAndRunTaskAction(inputPlistData: commonProcessingInfoPlistData, scope: scope, platformName: "watchos") { result, dict, outputDelegate in
            // There will be a lot of keys in the dict which were added from the platform, so we only check the ones we're testing/
            #expect(dict["Foo"]?.stringValue ?? "" == "Bar")

            // Check that iOS-specific keys are not present.
            #expect(dict["LSRequiresIPhoneOS"] == nil)

            // Check that only the watchOS-specific values exist.
            let backgroundModes = try #require(dict["UIBackgroundModes"]?.stringArrayValue)
            #expect(backgroundModes.contains("audio"))
            #expect(backgroundModes.contains("location"))
            #expect(backgroundModes.contains("voip"))
            #expect(!backgroundModes.contains("fetch"))
            #expect(backgroundModes.contains("remote-notification"))
            #expect(!backgroundModes.contains("newsstand-content"))
            #expect(!backgroundModes.contains("external-accessory"))
            #expect(backgroundModes.contains("bluetooth-central"))
            #expect(!backgroundModes.contains("bluetooth-peripheral"))
            #expect(!backgroundModes.contains("network-authentication"))
            #expect(!backgroundModes.contains("nearby-interaction"))
            #expect(!backgroundModes.contains("processing"))
            #expect(!backgroundModes.contains("push-to-talk"))

            // Check that there were no issues.
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])

            // Check expected content in the output stream.  This doesn't need to be exhaustive for all keys as the goal of this check is to make sure that the note in the transcript doesn't completely break.
            let output = outputDelegate.textBytes.asString
            XCTAssertMatch(output, .contains("removing entry for \"LSApplicationCategoryType\" - not supported on watchOS"))
        }
    }

    @Test(.requireSDKs(.watchOS))
    func tSanSpecialKeyAddition() async throws {
        let core = try await getCore()
        func testTSanSpecialKeyAddition(platformName: String, productType: String?, additionalBuildSettings: [String: String] = [:], expectedKeyValue: Bool?) async throws {
            let scope = try createMockScope { namespace, table in
                table.push(try #require(namespace.lookupMacroDeclaration("ENABLE_THREAD_SANITIZER") as? BooleanMacroDeclaration), literal: true)
                for (settingName, value) in additionalBuildSettings {
                    table.push(try #require(namespace.lookupMacroDeclaration(settingName) as? StringMacroDeclaration), literal: value)
                }
            }
            let productTypeSpec: ProductTypeSpec?
            do {
                productTypeSpec = try productType.map { try core.specRegistry.getSpec($0, domain: platformName) as ProductTypeSpec }
            } catch {
                Issue.record("\(error)")
                return
            }
            let platformName = "macosx"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: productTypeSpec, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

            // Write the test files.
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [:])

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            guard result == .succeeded else {
                Issue.record("task failed; errors: \(outputDelegate.errors)")
                return
            }

            // Check the output.
            do {
                // Read the output property list.
                let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
                let plist = try PropertyList.fromBytes(contents.bytes)
                guard case .plDict(let dict) = plist else {
                    Issue.record("Output property list is not a dictionary.")
                    return
                }

                #expect(dict["NSBuiltWithThreadSanitizer"]?.boolValue == expectedKeyValue)
            }
        }

        try await testTSanSpecialKeyAddition(platformName: "macosx", productType: nil, expectedKeyValue: true)
        try await testTSanSpecialKeyAddition(platformName: "watchos", productType: "com.apple.product-type.application.watchapp2", additionalBuildSettings: ["WATCHOS_DEPLOYMENT_TARGET": "5.0"], expectedKeyValue: nil)
        try await testTSanSpecialKeyAddition(platformName: "watchos", productType: "com.apple.product-type.application.watchapp2", additionalBuildSettings: ["WATCHOS_DEPLOYMENT_TARGET": "6.0"], expectedKeyValue: true)
        try await testTSanSpecialKeyAddition(platformName: "watchos", productType: nil, additionalBuildSettings: ["WATCHOS_DEPLOYMENT_TARGET": "5.0"], expectedKeyValue: true)
        try await testTSanSpecialKeyAddition(platformName: "watchos", productType: nil, additionalBuildSettings: ["WATCHOS_DEPLOYMENT_TARGET": "6.0"], expectedKeyValue: true)
    }

    @Test
    func infoPlistWithRequiredArchitecturesEmpty() async throws {
        let core = try await getCore()
        let scope = try createMockScope()
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: core)

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "-requiredArchitecture", "arm64", "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [:])

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            #expect(dict["UIRequiredDeviceCapabilities"]?.arrayValue ?? [] == [.plString("arm64")])
        }
    }

    @Test
    func infoPlistWithRequiredArchitecturesArray() async throws {
        let core = try await getCore()
        let scope = try createMockScope { namespace, table in
            try namespace.declareBooleanMacro("GENERATE_INFOPLIST_FILE")
            try namespace.declareStringListMacro("INFOPLIST_KEY_UIRequiredDeviceCapabilities")
            table.push(try #require(namespace.lookupMacroDeclaration("GENERATE_INFOPLIST_FILE") as? BooleanMacroDeclaration), literal: true)
            table.push(try #require(namespace.lookupMacroDeclaration("INFOPLIST_KEY_UIRequiredDeviceCapabilities") as? StringListMacroDeclaration), literal: ["arkit"])
        }
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "-requiredArchitecture", "arm64", "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
            "UIRequiredDeviceCapabilities": ["arm64"],
        ])

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            #expect(dict["UIRequiredDeviceCapabilities"]?.arrayValue ?? [] == [.plString("arm64"), .plString("arkit")])
        }
    }

    @Test
    func infoPlistWithRequiredArchitecturesDictionary() async throws {
        let core = try await getCore()
        let scope = try createMockScope()
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "-requiredArchitecture", "arm64", "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
            "UIRequiredDeviceCapabilities": [
                "arm64": true
            ]
        ])

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            #expect(dict["UIRequiredDeviceCapabilities"]?.dictValue ?? [:] == ["arm64": .plBool(true)])
        }
    }

    @Test
    func infoPlistRequiredArchitecturesCleanup() async throws {
        let core = try await getCore()
        let scope = try createMockScope()
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: ["armv6", "armv7", "armv64"]), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "-requiredArchitecture", "arm64", "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
            "UIRequiredDeviceCapabilities": [
                "armv6": true
            ],
        ])

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            #expect(dict["UIRequiredDeviceCapabilities"]?.dictValue ?? [:] == ["arm64": .plBool(true)])
        }
    }

    /// Test that `GENERATE_INFOPLIST_FILE` merely being enabled doesn't remove existing keys in the Info.plist if the corresponding build setting is not defined. For example, if `MARKETING_VERSION` is not set, any value for `CFBundleShortVersionString` in the input Info.plist should remain in the output Info.plist.
    @Test
    func generatedInfoPlistWithExistingKeys() async throws {
        let core = try await getCore()
        let scope = try createMockScope { namespace, table in
            try namespace.declareBooleanMacro("GENERATE_INFOPLIST_FILE")
            table.push(try #require(namespace.lookupMacroDeclaration("GENERATE_INFOPLIST_FILE") as? BooleanMacroDeclaration), literal: true)
            try table.remove(namespace.declareStringMacro("MARKETING_VERSION"))
        }
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), .plDict([
            "CFBundleShortVersionString": .plString("1.0"),
        ]))

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            #expect(dict["CFBundleShortVersionString"]?.stringValue == "1.0")
        }
    }

    @Test
    func bundleIdentifierWithAllValidCharacters() async throws {
        let core = try await getCore()
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER, literal: "abcdefghijklmnopqrstuvwxyz-0123456789.ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let scope = MacroEvaluationScope(table: table)
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
            "CFBundleIdentifier": "abcdefghijklmnopqrstuvwxyz-0123456789.ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        ])
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.warnings == [])
    }

    /// Tests that bundle identifiers prefixed with the developer's team identifier (this is required for some bundles such as login items) validate correctly even if the team identifier starts with a leading digit.
    @Test
    func bundleIdentifierWithTeamIdentifierPrefix() async throws {
        let core = try await getCore()
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER, literal: "32XN53XSGF.com.apple.foo")
        let scope = MacroEvaluationScope(table: table)
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
            "CFBundleIdentifier": "32XN53XSGF.com.apple.foo"
        ])
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.warnings == [])
    }

    @Test
    func bundleIdentifierWithInvalidCharacters() async throws {
        let core = try await getCore()
        func checkInvalidCharacterDiagnostics(bundleIdentifier: String, invalidCharacter: Character, column: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER, literal: bundleIdentifier)
            let scope = MacroEvaluationScope(table: table)
            let platformName = "macosx"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), ["CFBundleIdentifier": bundleIdentifier])
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .succeeded, sourceLocation: sourceLocation)
            #expect(outputDelegate.warnings.count == 1, sourceLocation: sourceLocation)
            #expect(outputDelegate.warnings[0] == "warning: invalid character in Bundle Identifier. This string must be a uniform type identifier (UTI) that contains only alphanumeric (A-Z,a-z,0-9), hyphen (-), and period (.) characters.", sourceLocation: sourceLocation)
        }

        try await checkInvalidCharacterDiagnostics(bundleIdentifier: "com.apple./foo", invalidCharacter: "/", column: 10)
        try await checkInvalidCharacterDiagnostics(bundleIdentifier: "com.:apple.foo", invalidCharacter: ":", column: 4)
        try await checkInvalidCharacterDiagnostics(bundleIdentifier: "com.@pple.foo", invalidCharacter: "@", column: 4)
        try await checkInvalidCharacterDiagnostics(bundleIdentifier: "com.apple.[foo", invalidCharacter: "[", column: 10)
        try await checkInvalidCharacterDiagnostics(bundleIdentifier: "`com.apple.foo`", invalidCharacter: "`", column: 0)
        try await checkInvalidCharacterDiagnostics(bundleIdentifier: "com.apple.foo{bar}", invalidCharacter: "{", column: 13)
    }

    @Test
    func bundlePackageTypeAndBundleSignatureAreProperlyEvaluated() async throws {
        let core = try await getCore()
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(try namespace.declareStringMacro("package_type"), literal: "PKTY")
        table.push(try namespace.declareStringMacro("package_signature"), literal: "pksn")

        let scope = MacroEvaluationScope(table: table)
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist", "-genpkginfo", "/tmp/PkgInfo"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
            "CFBundlePackageType": "$(package_type)",
            "CFBundleSignature": "$(package_signature)"
        ])
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.warnings.count == 0)

        guard let plDict = try PropertyList.fromBytes(executionDelegate.fs.read(Path("/tmp/output.plist")).bytes).dictValue else {
            Issue.record("/tmp/output.plist seems to be an invalid plist file")
            return
        }
        #expect(plDict["CFBundlePackageType"]?.stringValue == "PKTY")
        #expect(plDict["CFBundleSignature"]?.stringValue == "pksn")

        #expect(try executionDelegate.fs.read(Path("/tmp/PkgInfo")).stringValue == "PKTYpksn")
    }

    @Test
    func fourCodeCharacterDiagnosticForGeneratingPackage() async throws {
        let core = try await getCore()
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
        let table = MacroValueAssignmentTable(namespace: namespace)
        let scope = MacroEvaluationScope(table: table)

        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let sdk = try #require(core.sdkRegistry.lookup(platformName), "invalid SDK name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: sdk, sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist", "-genpkginfo", "/tmp/PkgInfo"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
            "CFBundlePackageType": "package_type",
            "CFBundleSignature": "package_signature"
        ])

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        #expect(outputDelegate.warnings == [
            "warning: value 'package_type' for 'CFBundlePackageType' in 'Info.plist' must be a four character string",
            "warning: value 'package_signature' for 'CFBundleSignature' in 'Info.plist' must be a four character string",
        ])
    }

    @Test
    func bundleIdentifierNonString() async throws {
        let core = try await getCore()
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
        let table = MacroValueAssignmentTable(namespace: namespace)
        let scope = MacroEvaluationScope(table: table)
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), ["CFBundleIdentifier": [1, 2, 3]])
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.warnings.count == 1)
        #expect(outputDelegate.warnings[0] == "warning: the value for Bundle Identifier must be of type string, but is an array")
    }

    @Test
    func bundleIdentifierBuildSettingMismatch() async throws {
        let core = try await getCore()
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER, literal: "foo")
        let scope = MacroEvaluationScope(table: table)
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), ["CFBundleIdentifier": "bar"])
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.warnings == ["warning: User-supplied CFBundleIdentifier value 'bar' in the Info.plist must be the same as the PRODUCT_BUNDLE_IDENTIFIER build setting value 'foo'."])
    }

    @Test(.requireSDKs(.watchOS))
    func CLKComplicationSupportedFamiliesDeprecationWarning() async throws {
        let plistData: [String: PropertyListItem] = [
            // This is an array of stuff, but only the presence, not the contents, matters for this warning.
            "CLKComplicationSupportedFamilies": [
                "foo", "bar", "baz", "quux",
            ],
            "MinimumOSVersion": "$($(DEPLOYMENT_TARGET_SETTING_NAME))",
        ]

        // Test that we don't emit the warning for watchOS < 7.0
        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("WATCHOS_DEPLOYMENT_TARGET"), literal: "6.0")
            table.push(try namespace.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME"), literal: "WATCHOS_DEPLOYMENT_TARGET")
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "watchos") { result, dict, outputDelegate in
                #expect(outputDelegate.warnings == [])
            }
        }

        // Test that we do emit the warning for watchOS = 7.0.
        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("WATCHOS_DEPLOYMENT_TARGET"), literal: "7.0")
            table.push(try namespace.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME"), literal: "WATCHOS_DEPLOYMENT_TARGET")
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "watchos") { result, dict, outputDelegate in
                #expect(outputDelegate.warnings == ["warning: 'CLKComplicationSupportedFamilies' has been deprecated starting in watchOS 7.0, use the ClockKit complications API instead."])
            }
        }
    }

    let testUILaunchImagesDeprecationWarningPlistData: [String: PropertyListItem] = [
        // This is an array of stuff, but only the presence, not the contents, matters for this warning.
        "UILaunchImages": [
            "foo", "bar", "baz", "quux",
        ],
        "MinimumOSVersion": "$($(DEPLOYMENT_TARGET_SETTING_NAME))",
    ]

    @Test(.requireSDKs(.iOS))
    func UILaunchImagesDeprecationWarning_iOS() async throws {
        // Test that we always emit the warning for iOS.
        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("IPHONEOS_DEPLOYMENT_TARGET"), literal: "13.0")
            table.push(try namespace.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME"), literal: "IPHONEOS_DEPLOYMENT_TARGET")
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: testUILaunchImagesDeprecationWarningPlistData, scope: scope, platformName: "iphoneos") { result, dict, outputDelegate in
                #expect(outputDelegate.warnings.count == 1)
                #expect(outputDelegate.warnings[0] == "warning: 'UILaunchImages' has been deprecated, use launch storyboards instead.")
            }
        }
    }

    @Test(.requireSDKs(.tvOS))
    func UILaunchImagesDeprecationWarning_tvOSLegacy() async throws {
        // Test that we don't emit the warning for tvOS < 13.0
        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("TVOS_DEPLOYMENT_TARGET"), literal: "10.0")
            table.push(try namespace.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME"), literal: "TVOS_DEPLOYMENT_TARGET")
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: testUILaunchImagesDeprecationWarningPlistData, scope: scope, platformName: "appletvos") { result, dict, outputDelegate in
                #expect(outputDelegate.warnings.count == 0)
            }
        }
    }

    @Test(.requireSDKs(.tvOS))
    func UILaunchImagesDeprecationWarning_tvOS() async throws {
        // Test that we do emit the warning for tvOS = 13.0.
        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro("TVOS_DEPLOYMENT_TARGET"), literal: "13.0")
            table.push(try namespace.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME"), literal: "TVOS_DEPLOYMENT_TARGET")
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: testUILaunchImagesDeprecationWarningPlistData, scope: scope, platformName: "appletvos") { result, dict, outputDelegate in
                #expect(outputDelegate.warnings.count == 1)
                #expect(outputDelegate.warnings[0] == "warning: 'UILaunchImages' has been deprecated starting in tvOS 13.0, use launch storyboards instead.")
            }
        }
    }

    let testNSExceptionMinimumTLSVersionDeprecationWarningPlistData: [String: PropertyListItem] = [
        "NSAppTransportSecurity": [
            "NSExceptionDomains": [
                "apple.com": [
                    "NSExceptionMinimumTLSVersion": "TLSv1.0"
                ]
            ]
        ],
        "MinimumOSVersion": "$($(DEPLOYMENT_TARGET_SETTING_NAME))",
    ]

    func testNSExceptionMinimumTLSVersionDeprecationWarning(deploymentTargetSettingName: String, oldDeploymentTarget: String, newDeploymentTarget: String, platformName: String, platformFamilyName: String) async throws {
        // Test that we don't emit the warning for older deployment targets.
        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro(deploymentTargetSettingName), literal: oldDeploymentTarget)
            table.push(try namespace.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME"), literal: deploymentTargetSettingName)
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: testNSExceptionMinimumTLSVersionDeprecationWarningPlistData, scope: scope, platformName: platformName) { result, dict, outputDelegate in
                #expect(outputDelegate.warnings == [])
            }
        }

        // Test that we do emit the warning for newer deployment targets.
        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            var table = MacroValueAssignmentTable(namespace: namespace)
            table.push(try namespace.declareStringMacro(deploymentTargetSettingName), literal: newDeploymentTarget)
            table.push(try namespace.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME"), literal: deploymentTargetSettingName)
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: testNSExceptionMinimumTLSVersionDeprecationWarningPlistData, scope: scope, platformName: platformName) { result, dict, outputDelegate in
                #expect(outputDelegate.warnings == [
                    "warning: The value \"TLSv1.0\" for 'NSAppTransportSecurity' => 'NSExceptionDomains' => 'apple.com' => 'NSExceptionMinimumTLSVersion' has been deprecated starting in \(platformFamilyName) \(newDeploymentTarget), use TLSv1.2 or TLSv1.3 instead."
                ])
            }
        }
    }

    @Test
    func NSExceptionMinimumTLSVersionDeprecationWarning_macOS() async throws {
        try await testNSExceptionMinimumTLSVersionDeprecationWarning(deploymentTargetSettingName: "MACOSX_DEPLOYMENT_TARGET", oldDeploymentTarget: "11.0", newDeploymentTarget: "12.0", platformName: "macosx", platformFamilyName: "macOS")
    }

    @Test
    func NSExceptionMinimumTLSVersionDeprecationWarning_iOS() async throws {
        try await testNSExceptionMinimumTLSVersionDeprecationWarning(deploymentTargetSettingName: "IPHONEOS_DEPLOYMENT_TARGET", oldDeploymentTarget: "14.0", newDeploymentTarget: "15.0", platformName: "iphoneos", platformFamilyName: "iOS")
    }

    @Test
    func NSExceptionMinimumTLSVersionDeprecationWarning_tvOS() async throws {
        try await testNSExceptionMinimumTLSVersionDeprecationWarning(deploymentTargetSettingName: "TVOS_DEPLOYMENT_TARGET", oldDeploymentTarget: "14.0", newDeploymentTarget: "15.0", platformName: "appletvos", platformFamilyName: "tvOS")
    }

    @Test
    func NSExceptionMinimumTLSVersionDeprecationWarning_watchOS() async throws {
        try await testNSExceptionMinimumTLSVersionDeprecationWarning(deploymentTargetSettingName: "WATCHOS_DEPLOYMENT_TARGET", oldDeploymentTarget: "7.0", newDeploymentTarget: "8.0", platformName: "watchos", platformFamilyName: "watchOS")
    }

    @Test
    func iOSDocumentAppWithoutOpenInPlaceSetting() async throws {
        let core = try await getCore()
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER, literal: "a.b.c")
        let scope = MacroEvaluationScope(table: table)
        do {
            // Check that we don't get a warning if we don't declare document types (even if we have a 'CFBundleDocumentTypes' key but it's empty).
            let platformName = "iphoneos"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleIdentifier": "a.b.c",
                "CFBundleDocumentTypes": [] as PropertyListItem
            ])
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .succeeded)
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.errors == [])
        }
        do {
            // Check that we don't get a warning if we build for a platform other than iOS'
            let platformName = "macosx"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleIdentifier": "a.b.c",
                "CFBundleDocumentTypes": [
                    [   "CFBundleTypeRole": "Viewer",
                        "CFBundleTypeExtensions": [ "dat" ]
                    ] as PropertyListItem
                ]
            ])
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .succeeded)
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.errors == [])
        }
        do {
            // Check that we don't get a warning if we have a 'LSSupportsOpeningDocumentsInPlace' key (regardless of its value).
            let platformName = "iphoneos"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleIdentifier": "a.b.c",
                "CFBundleDocumentTypes": [
                    [   "CFBundleTypeRole": "Viewer",
                        "CFBundleTypeExtensions": [ "dat" ]
                    ] as PropertyListItem
                ],
                "LSSupportsOpeningDocumentsInPlace": false
            ])
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .succeeded)
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.errors == [])
        }
        do {
            // Check that we don't get a warning if we have a 'UISupportsDocumentBrowser' key (regardless of its value).
            let platformName = "iphoneos"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleIdentifier": "a.b.c",
                "CFBundleDocumentTypes": [
                    [   "CFBundleTypeRole": "Viewer",
                        "CFBundleTypeExtensions": [ "dat" ]
                    ] as PropertyListItem
                ],
                "UISupportsDocumentBrowser": false
            ])
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .succeeded)
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.errors == [])
        }
        do {
            // Check that we do get a warning if all the conditions are met.
            let platformName = "iphoneos"
            let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [
                "CFBundleIdentifier": "a.b.c",
                "CFBundleDocumentTypes": [
                    [   "CFBundleTypeRole": "Viewer",
                        "CFBundleTypeExtensions": [ "dat" ]
                    ] as PropertyListItem
                ],
            ])
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .succeeded)
            #expect(outputDelegate.warnings == ["warning: The application supports opening files, but doesn't declare whether it supports opening them in place. You can add an LSSupportsOpeningDocumentsInPlace entry or an UISupportsDocumentBrowser entry to your Info.plist to declare support."])
            #expect(outputDelegate.errors == [])
        }
    }

    @Test
    func macOSDocumentAppWithOpenInPlaceSettingNO() async throws {
        let scope = try createMockScope(debugDescription: #function) { namespace, table in
            table.push(try #require(namespace.lookupMacroDeclaration("PRODUCT_BUNDLE_IDENTIFIER") as? StringMacroDeclaration), literal: "a.b.c")
            table.push(try #require(namespace.lookupMacroDeclaration("SDK_VARIANT") as? StringMacroDeclaration), literal: MacCatalystInfo.sdkVariantName)
            table.push(try #require(namespace.lookupMacroDeclaration("TARGETED_DEVICE_FAMILY") as? StringMacroDeclaration), literal: "2")
        }

        // Check that an error is emitted when building for macOS and LSSupportsOpeningDocumentsInPlace is false.
        do {
            let plistData: [String: PropertyListItem] = [
                "CFBundleIdentifier": "a.b.c",
                "CFBundleDocumentTypes": [
                    [   "CFBundleTypeRole": "Viewer",
                        "CFBundleTypeExtensions": [ "dat" ]
                    ] as PropertyListItem
                ],
                "LSSupportsOpeningDocumentsInPlace": false,
            ]
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName) { result, dict, outputDelegate in
                #expect(result == .failed)

                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.errors == ["error: \'LSSupportsOpeningDocumentsInPlace = NO\' is not supported on macOS. Either remove the entry or set it to YES, and also ensure that the application does open documents in place on macOS."])
            }
        }

        // Check that no error is emitted if CFBundleDocumentTypes is not defined.
        do {
            let plistData: [String: PropertyListItem] = [
                "CFBundleIdentifier": "a.b.c",
                "LSSupportsOpeningDocumentsInPlace": false,
            ]
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName) { result, dict, outputDelegate in
                #expect(result == .succeeded)

                #expect(dict["CFBundleIdentifier"]?.stringValue == "a.b.c")
                #expect(dict["LSSupportsOpeningDocumentsInPlace"]?.boolValue == false)

                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.errors == [])
            }
        }

        // Check that no error is emitted if LSSupportsOpeningDocumentsInPlace is true.
        do {
            let plistData: [String: PropertyListItem] = [
                "CFBundleIdentifier": "a.b.c",
                "CFBundleDocumentTypes": [
                    [   "CFBundleTypeRole": "Viewer",
                        "CFBundleTypeExtensions": [ "dat" ]
                    ] as PropertyListItem
                ],
                "LSSupportsOpeningDocumentsInPlace": true,
            ]
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName) { result, dict, outputDelegate in
                #expect(result == .succeeded)

                #expect(outputDelegate.warnings == [])
                #expect(outputDelegate.errors == [])
            }
        }
    }

    @Test
    func defaultKeyAdditions() async throws {
        let core = try await getCore()
        let scope = try createMockScope()
        let platformName = "iphoneos"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let productTypeName = "com.apple.product-type.application"
        let productType = try #require(core.specRegistry.getSpec(productTypeName, domain: platformName) as? ProductTypeSpec)
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: productType, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-producttype", productTypeName, "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), [:])

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                #expect(dict["CFBundleExecutable"]?.stringValue == "TestApp")
                #expect(dict["CFBundleIdentifier"]?.stringValue == "com.apple.TestApp")
                #expect(dict["CFBundleInfoDictionaryVersion"]?.stringValue == "6.0")
                #expect(dict["CFBundleName"]?.stringValue == "TestApp")
                #expect(dict["LSRequiresIPhoneOS"]?.boolValue == true)
            } else {
                #expect(dict["CFBundleExecutable"] == nil)
                #expect(dict["CFBundleIdentifier"] == nil)
                #expect(dict["CFBundleInfoDictionaryVersion"] == nil)
                #expect(dict["CFBundleName"] == nil)
                #expect(dict["LSRequiresIPhoneOS"] == nil)
            }

            // Corresponding build settings weren't supplied, so these should be elided
            #expect(dict["CFBundleDevelopmentRegion"] == nil)
            #expect(dict["CFBundlePackageType"] == nil)
            #expect(dict["CFBundleVersion"] == nil)
        }
    }

    @Test
    func appClipUnusedKeysWarning() async throws {
        let plistData: [String: PropertyListItem] = [
            // This is an array of stuff, but only the presence, not the contents, matters for this warning.
            "CFBundleDocumentTypes": [],
            "LSApplicationQueriesSchemes": [],
        ]

        do {
            let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: #function)
            let table = MacroValueAssignmentTable(namespace: namespace)
            let scope = MacroEvaluationScope(table: table)
            try await createAndRunTaskAction(inputPlistData: plistData, scope: scope, platformName: "iphoneos", productTypeId: "com.apple.product-type.application.on-demand-install-capable") { result, dict, outputDelegate in
                #expect(outputDelegate.warnings == [
                    "warning: 'CFBundleDocumentTypes' has no effect for App Clip targets and will be ignored.",
                    "warning: 'LSApplicationQueriesSchemes' has no effect for App Clip targets and will be ignored.",
                ])
            }
        }
    }

    /// Test behaviors specific to merging the content from `PrivacyInfo.xcprivacy` files within the target's dependencies.
    func _testMergingTrackedDomainsInfo(domains: [String]) async throws {
        let core = try await getCore()

        do {
            let scope = try createMockScope(debugDescription: "\(#function)_macOS")
            let platformName = "macosx"
            let executionDelegate = MockExecutionDelegate(core: try await getCore())

            let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: core.platformRegistry.lookup(name: platformName), sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-enforceminimumos", "-genpkginfo", "/tmp/PkgInfo", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-scanforprivacyfile", "/tmp/frameworkA.framework", "-scanforprivacyfile", "/tmp/frameworkB.framework", "-scanforprivacyfile", "/tmp/frameworkC.framework", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

            var appPlist: PropertyListItem = .plDict([
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleSignature": "FOOZ",
                "CFBundleVersion": "1",
                "NSMainNibFile": "MainMenu",
                "NSPrincipalClass": "NSApplication",
                "NSPrivacyTracking": true,
            ])

            if !domains.isEmpty {
                if let dict = appPlist.dictValue {
                    var dict = dict
                    dict["NSPrivacyTrackingDomains"] = .plArray(domains.map { .plString($0)} )
                    appPlist = .plDict(dict)
                }
            }

            // Write the test files.
            try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
            try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), appPlist)

            try executionDelegate.fs.createDirectory(Path("/tmp/frameworkA.framework"))
            try await executionDelegate.fs.writePlist(Path("/tmp/frameworkA.framework/PrivacyInfo.xcprivacy"), [
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.frameworka.com",
                    "internal.frameworka.com",
                    "www.allframeworks.com",
                ]
            ])

            try executionDelegate.fs.createDirectory(Path("/tmp/frameworkB.framework/Resources"), recursive: true)
            try await executionDelegate.fs.writePlist(Path("/tmp/frameworkB.framework/Resources/PrivacyInfo.xcprivacy"), [
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.allframeworks.com",
                    "internal.frameworkb.com",
                    "www.frameworkb.com",
                ]
            ])
            // Generic *.xcprivacy files are not supported, they must be named `PrivacyInfo.xcprivacy`; this is currently by convention.
            try executionDelegate.fs.createDirectory(Path("/tmp/frameworkC.framework/Resources"), recursive: true)
            try await executionDelegate.fs.writePlist(Path("/tmp/frameworkC.framework/Resources/Nope.privacy"), [
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.nope.com",
                ]
            ])

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            guard result == .succeeded else {
                Issue.record("task failed; errors: \(outputDelegate.errors)")
                return
            }

            // Check the output.
            do {
                // Read the output property list.
                let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
                let plist = try PropertyList.fromBytes(contents.bytes)
                guard case .plDict(let dict) = plist else {
                    Issue.record("Output property list is not a dictionary.")
                    return
                }

                // Check some of the original values are there.
                #expect(dict["NSMainNibFile"]?.stringValue == "MainMenu")
                #expect(dict["NSPrincipalClass"]?.stringValue == "NSApplication")
                #expect(dict["NSPrivacyTracking"]?.boolValue == true)

                // Check the merged tracked domains.
                let trackedDomains = (dict["NSPrivacyTrackingDomains"]?.arrayValue ?? []).compactMap({ $0.stringValue })

                let expectedDomains = {
                    var items = [
                        "internal.frameworka.com",
                        "internal.frameworkb.com",
                        // There should be no duplicates
                        "www.allframeworks.com",
                        "www.frameworka.com",
                        "www.frameworkb.com",
                    ]
                    items.append(contentsOf: domains)
                    return items.sorted()
                }()
                XCTAssertEqualSequences(trackedDomains, expectedDomains)
            }
        }

        // We presently don't test the other platforms' AdditionalInfo dictionaries, because we haven't identified that they differ from macOS in ways that we need to test.  But if we do determine that, then we can replicate the code above and tweak it as appropriate.
    }

    @Test(.requireSDKs(.macOS))
    func mergingTrackedDomainsInfo_WithTopLevelAppDomains() async throws {
        try await _testMergingTrackedDomainsInfo(domains: ["www.apple.com"])
    }

    @Test(.requireSDKs(.macOS))
    func mergingTrackedDomainsInfo_WithNoTopLevelAppDomains() async throws {
        try await _testMergingTrackedDomainsInfo(domains: [])
    }

    // Create a plist containing `CFBundleIcons` and merge with a partial plist similar to one generated by actool.
    @Test
    func mergeCFBundleIcons() async throws {
        let core = try await getCore()
        let scope = try createMockScope()
        let platformName = "macosx"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let sdk = try #require(core.sdkRegistry.lookup(platformName), "invalid SDK name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: sdk, sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-enforceminimumos", "-genpkginfo", "/tmp/PkgInfo", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-additionalcontentfile", "/tmp/mergecontent.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))

        // Developers configure complementing icon colors in their Info.plist file.
        // These values should be preserved when merged with generated content from `actool`,
        // as long as they don't conflict. When they conflict, generated content replaces
        // content in the Info.plist file. Eventually, `actool` will generate these values
        // directly.
        let inputContent = PropertyListItem.plDict([
            "CFBundleAlternateIcons": [
                "AppIcon2": [
                    "NSAppIconComplementingColorName": "AppIcon2-ComplementingColorName",
                ],
                "AppIcon3": [
                    "NSAppIconComplementingColorName": "AppIcon3-ComplementingColorName",
                ],
            ],
            "CFBundlePrimaryIcon": [
                "NSAppIconComplementingColors": [
                    "NSAppIconActionTintOverrideColor": "AppIcon-ActionTintOverrideColor",
                    "NSAppIconComplementingColorName": "AppIcon-ComplementingColorName",
                ],
                // Overwrite conflicting keys with generated values.
                "CFBundleIconFiles": PropertyListItem.plArray([
                    "ReplaceMe",
                ]),
                "CFBundleIconName": "ReplaceMe",
            ],
        ])
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), .plDict([
            "CFBundleIcons": inputContent,
            "CFBundleIcons~ipad": inputContent,
        ]))

        // `actool` generates a partial Info.plist similar to this for app icons.
        let mergeContent = PropertyListItem.plDict([
            "CFBundleAlternateIcons": [
                "AppIcon2": [
                    "CFBundleIconName": "AppIcon2",
                ],
                "AppIcon3": [
                    "CFBundleIconName": "AppIcon3",
                ],
                "PreserveMe": [
                    "Key": "Value"
                ],
            ],
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": PropertyListItem.plArray([
                    "AppIcon60x60",
                ]),
                "CFBundleIconName": "AppIcon",
            ],
            // Merge in generated values that don't already exist in Info.plist.
            "PreserveMe": [
                "Key": "Value"
            ],
        ])
        try await executionDelegate.fs.writePlist(Path("/tmp/mergecontent.plist"), [
            "CFBundleIcons": mergeContent,
            "CFBundleIcons~ipad": mergeContent,
        ])

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        // Check the output.
        do {
            // Read the output property list.
            let contents = try executionDelegate.fs.read(Path("/tmp/output.plist"))
            let plist = try PropertyList.fromBytes(contents.bytes)
            guard case .plDict(let dict) = plist else {
                Issue.record("Output property list is not a dictionary.")
                return
            }

            let expectedMerge = PropertyListItem.plDict([
                "CFBundleAlternateIcons": [
                    "AppIcon2": [
                        "NSAppIconComplementingColorName": "AppIcon2-ComplementingColorName",
                        "CFBundleIconName": "AppIcon2",
                    ],
                    "AppIcon3": [
                        "NSAppIconComplementingColorName": "AppIcon3-ComplementingColorName",
                        "CFBundleIconName": "AppIcon3",
                    ],
                    "PreserveMe": [
                        "Key": "Value"
                    ],
                ],
                "CFBundlePrimaryIcon": [
                    "NSAppIconComplementingColors": [
                        "NSAppIconActionTintOverrideColor": "AppIcon-ActionTintOverrideColor",
                        "NSAppIconComplementingColorName": "AppIcon-ComplementingColorName",
                    ],
                    "CFBundleIconFiles": PropertyListItem.plArray([
                        "AppIcon60x60",
                    ]),
                    "CFBundleIconName": "AppIcon",
                ],
                "PreserveMe": [
                    "Key": "Value"
                ],
            ])

            // Check plist merge result against expected value.
            XCTAssertEqualPropertyListItems(dict["CFBundleIcons"], expectedMerge)
            XCTAssertEqualPropertyListItems(dict["CFBundleIcons~ipad"], expectedMerge)
        }
    }

    @Test
    func usageDescriptionKeyWarning() async throws {
        let core = try await getCore()
        let scope = try createMockScope { namespace, table in
            try namespace.declareBooleanMacro("GENERATE_INFOPLIST_FILE")
            table.push(try #require(namespace.lookupMacroDeclaration("GENERATE_INFOPLIST_FILE") as? BooleanMacroDeclaration), literal: true)
            try table.remove(namespace.declareStringMacro("MARKETING_VERSION"))
        }
        let platformName = "iphoneos"
        let platform = try #require(core.platformRegistry.lookup(name: platformName), "invalid platform name '\(platformName)'")
        let executionDelegate = MockExecutionDelegate(core: try await getCore())

        let action = InfoPlistProcessorTaskAction(try prepareContext(InfoPlistProcessorTaskActionContext(scope: scope, productType: nil, platform: platform, sdk: core.sdkRegistry.lookup(platformName), sdkVariant: nil, cleanupRequiredArchitectures: []), fs: executionDelegate.fs))
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-infoPlistUtility", "-expandbuildsettings", "-platform", platformName, "/tmp/input.plist", "-o", "/tmp/output.plist"], workingDirectory: Path.root.join("tmp"), outputs: [], action: action, execDescription: "Copy Info.plist")

        // Write the test files.
        try executionDelegate.fs.createDirectory(Path.root.join("tmp"))
        try await executionDelegate.fs.writePlist(Path("/tmp/input.plist"), .plDict([
            "CFBundleIconName": .plString(""),
            "NSHomeKitUsageDescription": .plString(""),
            "NSSiriUsageDescription": .plBool(true),
            "NSFaceIDUsageDescription": .plString("Used for authentication."),
        ]))

        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        guard result == .succeeded else {
            Issue.record("task failed; errors: \(outputDelegate.errors)")
            return
        }

        let warnings = outputDelegate.warnings

        #expect(warnings.count == 2)
        #expect(warnings.contains("warning: The value for NSHomeKitUsageDescription must be a non-empty string."))
        #expect(warnings.contains("warning: The value for NSSiriUsageDescription must be of type string, but is a boolean."))
    }
}
