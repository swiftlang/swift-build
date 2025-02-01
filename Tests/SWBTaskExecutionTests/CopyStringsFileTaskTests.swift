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
import SWBLibc
import SWBUtil
import SWBTaskExecution

import SWBCore

@Suite(.requireHostOS(.macOS)) // many tests here crash or fail on Linux
fileprivate struct CopyStringsFileTaskTests {
    static let bom_utf8 = [UInt8]([0xEF, 0xBB, 0xBF])
    static let bom_utf16be = [UInt8]([0xFE, 0xFF])
    static let bom_utf16le = [UInt8]([0xFF, 0xFE])
    static let bom_utf32be = [UInt8]([0x00, 0x00, 0xFE, 0xFF])
    static let bom_utf32le = [UInt8]([0xFF, 0xFE, 0x00, 0x00])

    #if canImport(Darwin)
    static let bom_utf16_host: [UInt8] = {
        switch __CFByteOrder(UInt32(CFByteOrderGetCurrent())) {
        case CFByteOrderBigEndian:
            return bom_utf16be
        case CFByteOrderLittleEndian:
            return bom_utf16le
        default:
            return []
        }
    }()

    static let bom_utf32_host: [UInt8] = {
        switch __CFByteOrder(UInt32(CFByteOrderGetCurrent())) {
        case CFByteOrderBigEndian:
            return bom_utf32be
        case CFByteOrderLittleEndian:
            return bom_utf32le
        default:
            return []
        }
    }()
    #endif

    @Test
    func diagnostics() async {
        func checkDiagnostics(_ commandLine: [String], errors: [String] = [], warnings: [String] = [], notes: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) async
        {
            let action = CopyStringsFileTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Copy Localization Strings File")
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

        await checkDiagnostics([], errors: ["no input files specified", "missing required option: --outdir"])
        await checkDiagnostics(["copyStrings", "--", "foo.strings"], errors: ["missing required option: --outdir"])
        await checkDiagnostics(["copyStrings", "--outdir"], errors: ["missing argument for option: --outdir", "no input files specified"])
        await checkDiagnostics(["copyStrings", "--inputencoding"], errors: ["missing argument for option: --inputencoding", "no input files specified", "missing required option: --outdir"])
        await checkDiagnostics(["copyStrings", "--outputencoding"], errors: ["missing argument for option: --outputencoding", "no input files specified", "missing required option: --outdir"])
        await checkDiagnostics(["copyStrings", "--inputencoding", "foo", "--outputencoding", "bar", "--outdir", "/", "--", "foo.plist"], errors: ["/foo.plist: unable to read input file: No such file or directory (2)"], warnings: [])
        await checkDiagnostics(["copyStrings", "--what", "--outdir", "/", "--", "foo.plist"], errors: ["unrecognized argument: --what"])
    }


    let inputContents =
    "//\n" +
    "// input.strings\n" +
    "//\n" +
    "\n" +
    "// SomeValue\n" +
    "\"SomeValue\" = \"This is the first value.\";\n" +
    "\n" +
    "// Another Value\n" +
    "\"Another Value\" = \"This is the second value.\";\n"

    @Test
    func uTF8ImpliedToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf8)!
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == ["note: /tmp/inputs/input.strings: detected encoding of input file as Unicode (UTF-8)"])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

    @Test
    func keepInfoPlistStrings() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate","--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input-InfoPlist.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()



        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = try #require(inputContents.data(using: String.Encoding.utf8))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input-InfoPlist.strings"), contents: byteString)

        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == ["note: /tmp/inputs/input-InfoPlist.strings: detected encoding of input file as Unicode (UTF-8)"])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = try #require(inputContents.data(using: String.Encoding.utf16))
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input-InfoPlist.strings")) == byteString)
            #expect(!executionDelegate.fs.exists(Path("/tmp/outputs/InfoPlist.strings")))
        }
    }

    @Test
    func renameInfoPlistStringsName() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--outfilename", "InfoPlist.strings", "--", "/tmp/inputs/input-InfoPlist.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = try #require(inputContents.data(using: String.Encoding.utf8))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input-InfoPlist.strings"), contents: byteString)

        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == ["note: /tmp/inputs/input-InfoPlist.strings: detected encoding of input file as Unicode (UTF-8)"])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = try #require(inputContents.data(using: String.Encoding.utf16))
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/InfoPlist.strings")) == byteString)
            #expect(executionDelegate.fs.exists(Path("/tmp/outputs/InfoPlist.strings")))
        }
    }

    @Test
    func UTF8ImpliedBOMToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = ("\u{FEFF}" + inputContents).data(using: String.Encoding.utf8)!
            let byteString = ByteString(CopyStringsFileTaskTests.bom_utf8) + ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == ["note: /tmp/inputs/input.strings: detected encoding of input file as Unicode (UTF-8)", "note: /tmp/inputs/input.strings:1:1: ignoring byte-order mark in input file"])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

    @Test
    func UTF16ImpliedToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-16 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == ["note: /tmp/inputs/input.strings: detected encoding of input file as Unicode (UTF-16)"])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

    @Test
    func UTF8ToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf8)!
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            let outputContents = try executionDelegate.fs.read(Path("/tmp/outputs/input.strings"))

            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(outputContents == byteString)
        }
    }

    @Test
    func UTF8BOMToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = ("\u{FEFF}" + inputContents).data(using: String.Encoding.utf8)!
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == ["note: /tmp/inputs/input.strings:1:1: ignoring byte-order mark in input file"])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

    #if canImport(Darwin)
    @Test func UTF16ToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-16", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-16 encoding.
        let inputByteString: ByteString
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf16)!
            #expect(data.starts(with: CopyStringsFileTaskTests.bom_utf16_host))
            let byteString = ByteString(data)
            inputByteString = byteString
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            let outputContents = try executionDelegate.fs.read(Path("/tmp/outputs/input.strings"))

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(outputContents == inputByteString)
        }
    }
    #endif

    @Test
    func UTF16BEToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-16be", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-16 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf16BigEndian)!
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf16be))
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf16le))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

    @Test
    func UTF16LEToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-16le", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-16 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf16LittleEndian)!
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf16be))
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf16le))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-16-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

#if canImport(Darwin)
    func testUTF32ToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-32", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-32 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf32)!
            #expect(data.starts(with: CopyStringsFileTaskTests.bom_utf32_host))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-32-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }
#endif

    @Test
    func UTF32BEToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-32be", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-32 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf32BigEndian)!
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf32be))
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf32le))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-32-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

    @Test
    func UTF32LEToUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-32le", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-32 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf32LittleEndian)!
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf32be))
            #expect(!data.starts(with: CopyStringsFileTaskTests.bom_utf32le))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            // Get the input strings in UTF-16 encoding.
            let data = inputContents.data(using: String.Encoding.utf16)!
            let byteString = ByteString(data)

            // Compare what the tool emitted to the UTF-32-encoded version of the input content.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == byteString)
        }
    }

    @Test
    func UTF8ToBinaryPlist() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "binary", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = inputContents.data(using: String.Encoding.utf8)!
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        do {
            let outputContents = try executionDelegate.fs.read(Path("/tmp/outputs/input.strings"))

            // Convert the input string to a property list.
            let inputPlist = try PropertyList.fromString(inputContents)

            // Convert the output string to a property list.
            let (outputPlist, format) = try PropertyList.fromBytesWithFormat(outputContents.bytes)

            // Compare the input and output plists, and the format of the output plist
            #expect(outputPlist == inputPlist)
            #expect(format == .binary)
        }
    }

    @Test
    func wrongEncoding() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-16be", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file with a single UTF-16 unpaired high surrogate code unit (an invalid string).
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = Data([0xD8, 0x00])
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .failed)
        #expect(outputDelegate.errors == ["error: /tmp/inputs/input.strings: could not decode input file using specified encoding: Unicode (UTF-16BE)"])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        #expect(!executionDelegate.fs.exists(Path("/tmp/outputs/input.strings")))
    }

    @Test
    func wrongEncodingUTF8ReallyUTF16() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file using UTF-16 with BOM
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = Data([0xFF, 0xFE, 0x00, 0x00])
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .failed)
        #expect(outputDelegate.errors == ["error: /tmp/inputs/input.strings: could not decode input file using specified encoding: Unicode (UTF-8), and the file contents appear to be encoded in Unicode (UTF-16)"])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        #expect(!executionDelegate.fs.exists(Path("/tmp/outputs/input.strings")))
    }

    @Test
    func unknownEncoding() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = Data([0xD8, 0x00])
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .failed)
        #expect(outputDelegate.errors == ["error: /tmp/inputs/input.strings: no --inputencoding specified and could not detect encoding from input file"])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        #expect(!executionDelegate.fs.exists(Path("/tmp/outputs/input.strings")))
    }

    let badInputContents =
    "//\n" +
    "// input.strings\n" +
    "//\n" +
    "\n" +
    "// SomeValue\n" +
    "\"SomeValue\" = \"This is the first value.\"\n" +
    "\n" +
    "// Another Value\n" +
    "\"Another Value\" =| \"This is the second value.\"\n"

    @Test
    func validationFailure() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "utf-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = try #require(badInputContents.data(using: String.Encoding.utf8))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .failed)
        XCTAssertMatch(outputDelegate.errors, [.prefix("error: /tmp/inputs/input.strings: validation failed:")])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        #expect(!executionDelegate.fs.exists(Path("/tmp/outputs/input.strings")))
    }

    @Test
    func binaryPlistConversionFailure() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "binary", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file, in UTF-8 encoding.
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            let data = try #require(badInputContents.data(using: String.Encoding.utf8))
            let byteString = ByteString(data)
            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: byteString)
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .failed)
        XCTAssertMatch(outputDelegate.errors, [.prefix("error: /tmp/inputs/input.strings: validation failed:")])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output.
        #expect(!executionDelegate.fs.exists(Path("/tmp/outputs/input.strings")))
    }

    @Test
    func emptyFile() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--outputencoding", "binary", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: ByteString())
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])
    }

    @Test
    func emptyFileWithUTF16OutputEncoding() async throws {
        let action = CopyStringsFileTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outdir", "/tmp/outputs", "--", "/tmp/inputs/input.strings"], workingDirectory: Path("/tmp"), outputs: [], action: action, execDescription: "Copy Localization Strings File")

        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()

        // Create the input file
        do {
            try executionDelegate.fs.createDirectory(Path("/tmp"))
            try executionDelegate.fs.createDirectory(Path("/tmp/inputs"))
            try executionDelegate.fs.createDirectory(Path("/tmp/outputs"))

            try executionDelegate.fs.write(Path("/tmp/inputs/input.strings"), contents: ByteString())
        }

        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )

        // Check the exit state.
        #expect(result == .succeeded)
        #expect(outputDelegate.errors == [])
        #expect(outputDelegate.warnings == [])
        #expect(outputDelegate.notes == [])

        // Check the output is also empty.
        do {
            // Compare what the tool emitted to an empty byte string. The file has to be empty otherwise it'll trip up `plutil` when converting to binary plist.
            #expect(try executionDelegate.fs.read(Path("/tmp/outputs/input.strings")) == ByteString())
        }
    }
}
