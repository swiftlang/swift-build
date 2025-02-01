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
import SWBTestSupport
import SWBUtil
import SWBTaskExecution

@Suite
fileprivate struct SignatureCollectionActionTests {
    @Test(.requireHostOS(.macOS), .requireSDKs(.macOS))
    func signatureCollectionDiagnostics() async throws {
        let fs = PseudoFS()
        try fs.createDirectory(.root)

        func checkDiagnostics(_ commandLine: [String], errors: [String] = [], warnings: [String] = [], notes: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) async
        {
            let action = SignatureCollectionTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Signature Collection")
            let executionDelegate = MockExecutionDelegate(fs: fs)
            let outputDelegate = MockTaskOutputDelegate()

            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            #expect(result == (errors.isEmpty ? .succeeded : .failed), sourceLocation: sourceLocation)
            #expect(outputDelegate.errors == errors.map { "error: \($0)" }, sourceLocation: sourceLocation)
            #expect(outputDelegate.warnings == warnings.map { "warning: \($0)" }, sourceLocation: sourceLocation)
            #expect(outputDelegate.notes == notes.map { "note: \($0)" }, sourceLocation: sourceLocation)
        }

        await checkDiagnostics([], errors: ["missing required argument: --input"])
        await checkDiagnostics(["builtin-collectSignature", "--input", "/in"], errors: ["missing required argument: --output"])
        await checkDiagnostics(["builtin-collectSignature", "--input", "/in", "--output"], errors: ["missing argument for option: --output"])
        await checkDiagnostics(["builtin-collectSignature", "--input", Bundle.module.bundlePath, "--output", "/out.signature", "--info"], errors: ["missing key argument for option: --info"])
        await checkDiagnostics(["builtin-collectSignature", "--input", Bundle.module.bundlePath, "--output", "/out.signature", "--info", "library"], errors: ["missing value argument for option: --info"])
        await checkDiagnostics(["builtin-collectSignature", "--input", Bundle.module.bundlePath, "--output", "/out.signature"], errors: [])
    }

    @Test(.requireHostOS(.macOS), .requireSDKs(.macOS))
    func signatureCollectionOutputAppleSigned() async throws {
        let fs = PseudoFS()
        try fs.createDirectory(.root)

        let xcodePath = try await InstalledXcode.currentlySelected().developerDirPath.dirname.dirname

        let signaturePath = Path("/path/to/write/to/out.signature")
        let action = SignatureCollectionTaskAction()
        // --skip-signature-validation:
        //   the Xcode.app bundle is not always signed correctly, but the verification piece is not necessary for the validation here.
        let commandLine = ["builtin-collectSignature", "--input", xcodePath.str, "--output", signaturePath.str, "--skip-signature-validation"]
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Signature Collection")
        let executionDelegate = MockExecutionDelegate(fs: fs)
        let outputDelegate = MockTaskOutputDelegate()

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        let data = try fs.read(signaturePath)
        let decoder = PropertyListDecoder()
        let info = try decoder.decode(CodeSignatureInfo.self, from: Data(data))

        #expect(info.isSigned)
        #expect(info.identifier == "com.apple.dt.Xcode")
        #expect(info.signatureType == .appleDeveloperProgram)
        #expect(info.signatureIdentifier == "59GAB85EFG")
        #expect(!info.isSecureTimestamp)
        #expect(info.additionalInfo == nil)

        // We cannot validate the actual values for these as they change.
        #expect(info.certificates?.count > 0)
        #expect(info.cdHashes?.count > 0)
    }

    @Test(.requireHostOS(.macOS), .requireSDKs(.macOS), .skipSwiftPackage)
    func signatureCollectionOutputAdHocSigned() async throws {
        let fs = localFS

        try await withTemporaryDirectory(fs: fs) { tmpDir in
            let rootPath: Path = tmpDir.path
            let bundlePath = rootPath.join("test.bundle")
            try fs.copy(Path(Bundle.module.bundlePath), to: bundlePath)

            let codesignTool = URL(fileURLWithPath: "/usr/bin/codesign")
            let codesignResult = try await Process.run(url: codesignTool, arguments: ["--remove-signature", bundlePath.str])
            #expect(codesignResult.isSuccess)

            // Set-up the ad-hoc signed bundle for testing.
            let codesignSigningResult = try await Process.run(url: codesignTool, arguments: ["-s", "-", bundlePath.str])
            #expect(codesignSigningResult.isSuccess)

            let signaturePath = rootPath.join("out.signature")
            let action = SignatureCollectionTaskAction()
            let commandLine = ["builtin-collectSignature", "--input", bundlePath.str, "--output", signaturePath.str, "--info", "platform", "ios"]
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Signature Collection")
            let executionDelegate = MockExecutionDelegate(fs: fs)
            let outputDelegate = MockTaskOutputDelegate()

            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            #expect(result == .succeeded)
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])

            let data = try fs.read(signaturePath)
            let decoder = PropertyListDecoder()
            let info = try decoder.decode(CodeSignatureInfo.self, from: Data(data))

            #expect(info.isSigned)
            #expect(info.identifier == Bundle.module.bundleIdentifier)
            #expect(info.signatureType == nil)
            #expect(info.signatureIdentifier == nil)
            #expect(!info.isSecureTimestamp)
            #expect(info.additionalInfo?["platform"] == "ios")

            // We cannot validate the actual values for these as they change.
            #expect(info.cdHashes?.count > 0)

            // NOTE: Don't test the other properties as they may change.
        }
    }

    @Test(.requireHostOS(.macOS), .requireSDKs(.macOS))
    func signatureCollectionOutputNotSigned() async throws {
        let fs = localFS

        try await withTemporaryDirectory(fs: fs) { tmpDir in
            let rootPath: Path = tmpDir.path
            let bundlePath = rootPath.join("test.bundle")
            try fs.copy(Path(Bundle.module.bundlePath), to: bundlePath)

            let codesignTool = URL(fileURLWithPath: "/usr/bin/codesign")
            let codesignResult = try await Process.run(url: codesignTool, arguments: ["--remove-signature", bundlePath.str])
            #expect(codesignResult.isSuccess)

            let signaturePath = rootPath.join("out.signature")
            let action = SignatureCollectionTaskAction()
            let commandLine = ["builtin-collectSignature", "--input", bundlePath.str, "--output", signaturePath.str, "--info", "platform", "ios", "--info", "library", "test.bundle", "--info", "platformVariant", "macabi"]
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Signature Collection")
            let executionDelegate = MockExecutionDelegate(fs: fs)
            let outputDelegate = MockTaskOutputDelegate()

            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            #expect(result == .succeeded)
            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])
            #expect(outputDelegate.notes == [])

            let data = try fs.read(signaturePath)
            let decoder = PropertyListDecoder()
            let info = try decoder.decode(CodeSignatureInfo.self, from: Data(data))

            #expect(!info.isSigned)
            #expect(info.identifier == nil)
            #expect(info.signatureType == nil)
            #expect(info.signatureIdentifier == nil)
            #expect(info.additionalInfo?["platform"] == "ios")
            #expect(info.additionalInfo?["library"] == "test.bundle")
            #expect(info.additionalInfo?["platformVariant"] == "macabi")

            // We cannot validate the actual values for these as they change.
            #expect(info.cdHashes == nil)

            // NOTE: Don't test the other properties as they may change.
        }
    }

    @Test
    func SHA256HexString() {
        let bytes: [UInt8] = [ 0xDE, 0xAD, 0xBE, 0xEF ]
        let data = Data(bytes)
        let sha = data.sha256HexString
        #expect("5F78C33274E43FA9DE5659265C1D917E25C03722DCB0B8D27DB8D5FEAA813953" == sha)
    }
}
