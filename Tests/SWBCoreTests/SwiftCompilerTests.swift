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

import SWBUtil
import SWBProtocol
import SWBTestSupport
import SWBMacro
@_spi(Testing) import SWBCore
import Synchronization

fileprivate final class TestSwiftParserDelegate: TaskOutputParserDelegate, Sendable {
    let buildOperationIdentifier: BuildSystemOperationIdentifier

    let diagnosticsEngine = DiagnosticsEngine()

    struct State {
        var events: [(String, String)] = []
        var subtasks: [(name: String, delegate: TestSwiftParserDelegate, executionDescription: String, interestingPath: Path?, serializedDiagnosticsPaths: [Path])] = []
    }

    final class StateHolder: Sendable {
        let state = SWBMutex<State>(.init())
    }

    var events: [(String, String)] {
        state.state.withLock { $0.events }
    }

    var subtasks: [(name: String, delegate: TestSwiftParserDelegate, executionDescription: String, interestingPath: Path?, serializedDiagnosticsPaths: [Path])] {
        state.state.withLock { $0.subtasks }
    }

    let state: StateHolder

    init(buildOperationIdentifier: BuildSystemOperationIdentifier = .init(UUID())) {
        self.buildOperationIdentifier = buildOperationIdentifier
        let state = StateHolder()
        self.state = state
        self.diagnosticsEngine.addHandler { diag in
            state.state.withLock { state in
                state.events.append((diag.behavior.name, diag.formatLocalizedDescription(.debugWithoutBehavior)))
            }
        }
    }

    func skippedSubtask(signature: ByteString) {
        state.state.withLock { state in
            state.events.append(("skippedSubtask", signature.asString))
        }
    }

    func startSubtask(buildOperationIdentifier: BuildSystemOperationIdentifier, taskName: String, id: ByteString, signature: ByteString, ruleInfo: String, executionDescription: String, commandLine: [ByteString], additionalOutput: [String], interestingPath: Path?, workingDirectory: Path?, serializedDiagnosticsPaths: [Path]) -> any TaskOutputParserDelegate {
        state.state.withLock { state in
            state.events.append(("startSubtask", id.asString))
            let delegate = TestSwiftParserDelegate(buildOperationIdentifier: buildOperationIdentifier)
            state.subtasks.append((ruleInfo, delegate, executionDescription, interestingPath, serializedDiagnosticsPaths))
            return delegate
        }
    }
    func emitOutput(_ data: ByteString) {
        state.state.withLock { state in
            state.events.append(("output", data.asString))
        }
    }
    func taskCompleted(exitStatus: Processes.ExitStatus) {
        state.state.withLock { state in
            state.events.append(("taskCompleted", "exitStatus: \(exitStatus)"))
        }
    }

    func close() {}
}

@Suite fileprivate struct SwiftCompilerSpecTests: CoreBasedTests {
    /// Validate that the ABI version is being populated correctly.
    @Test(.skipHostOS(.windows, "receiving \"permission denied\" when running the executable"))
    func swiftABIVersionParsing() async throws {
        let core = try await getCore()
        guard let defaultToolchain = core.toolchainRegistry.lookup("default") else {
            Issue.record("couldn't lookup default toolchain")
            return
        }
        guard let swiftc = defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "swiftc") else {
            Issue.record("couldn't find swiftc in default toolchain")
            return
        }

        let swiftSpec = try await discoveredSwiftCompilerInfo(at: swiftc)

        var commandLine = [swiftc.str]
        commandLine.append("-v")

        // Invoke the tool and verify that the output string is of the correct form. This ensure that if `swiftc` outputs the ABI version info, that we are indeed parsing it correctly.
        let outputString = try await runProcess(commandLine, environment: [:], redirectStderr: true)
        if outputString.contains("ABI version") {
            guard let abiVersion = swiftSpec.swiftABIVersion else {
                Issue.record("Swift ABI version was not set correctly.")
                return
            }
            #expect(outputString.contains("ABI version: \(abiVersion)"))
        } else {
            #expect(swiftSpec.swiftABIVersion == nil)
        }
    }

    /// Check the standard library linking options.
    @Test(.requireHostOS(.macOS))
    func standardLibraryLinking() async throws {
        let core = try await getCore()

        // Computes the expected standard swift linker arguments.
        func additionalSwiftLinkerArgs(_ spec: CompilerSpec, _ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ stdlibPath: Path) -> [[String]] {
            return localFS.exists(stdlibPath) ? [["-L\(stdlibPath.str)"], ["-L/usr/lib/swift"]] : [["-L/usr/lib/swift"]]
        }

        let spec = try core.specRegistry.getSpec() as SwiftCompilerSpec

        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let swiftcPath = defaultToolchain.path.join("usr/bin/swiftc")

        // Check basics.
        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx", toolchain: core.toolchainRegistry.defaultToolchain)
            let stdlibPath = swiftcPath.dirname.dirname.join("lib/swift/macosx")
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftcPath.str)
            table.push(BuiltinMacros.SWIFT_STDLIB, literal: "swiftCore")
            table.push(BuiltinMacros.PLATFORM_NAME, literal: "macosx")
            let scope = MacroEvaluationScope(table: table)
            let delegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(), fs: localFS)
            let optionContext = await spec.discoveredCommandLineToolSpecInfo(producer, scope, delegate)
            try await #expect(spec.computeAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: [], optionContext: optionContext, delegate: CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)).args == additionalSwiftLinkerArgs(spec, producer, scope, stdlibPath))
        }

        // Check force static stdlib.
        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let stdlibPath = swiftcPath.dirname.dirname.join("lib/swift_static/fakeos")
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftcPath.str)
            table.push(BuiltinMacros.SWIFT_STDLIB, literal: "swiftCore")
            table.push(BuiltinMacros.PLATFORM_NAME, literal: "macosx")
            table.push(BuiltinMacros.SWIFT_FORCE_STATIC_LINK_STDLIB, literal: true)
            let scope = MacroEvaluationScope(table: table)
            let delegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(), fs: localFS)
            let optionContext = await spec.discoveredCommandLineToolSpecInfo(producer, scope, delegate)
            try await #expect(spec.computeAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: [], optionContext: optionContext, delegate: CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)).args == (additionalSwiftLinkerArgs(spec, producer, scope, stdlibPath)) + [["-Xlinker", "-force_load_swift_libs"], ["-lc++", "-framework", "Foundation"]])
        }

        // Check tool product type.
        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.tool", platform: "macosx", toolchain: core.toolchainRegistry.defaultToolchain)
            let stdlibPath = swiftcPath.dirname.dirname.join("lib/swift/macosx")
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftcPath.str)
            table.push(BuiltinMacros.SWIFT_STDLIB, literal: "swiftCore")
            table.push(BuiltinMacros.PLATFORM_NAME, literal: "macosx")
            let scope = MacroEvaluationScope(table: table)
            let delegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(), fs: localFS)
            let optionContext = await spec.discoveredCommandLineToolSpecInfo(producer, scope, delegate)
            try await #expect(spec.computeAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: [], optionContext: optionContext, delegate: CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)).args == additionalSwiftLinkerArgs(spec, producer, scope, stdlibPath))
        }

        // Check tool product type forced to dynamic link.
        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.tool", platform: "macosx", toolchain: core.toolchainRegistry.defaultToolchain)
            let stdlibPath = swiftcPath.dirname.dirname.join("lib/swift/macosx")
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftcPath.str)
            table.push(BuiltinMacros.SWIFT_STDLIB, literal: "swiftCore")
            table.push(BuiltinMacros.SWIFT_FORCE_DYNAMIC_LINK_STDLIB, literal: true)
            table.push(BuiltinMacros.PLATFORM_NAME, literal: "macosx")
            let scope = MacroEvaluationScope(table: table)
            let delegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(), fs: localFS)
            let optionContext = await spec.discoveredCommandLineToolSpecInfo(producer, scope, delegate)
            try await #expect(spec.computeAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: [], optionContext: optionContext, delegate: CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)).args == additionalSwiftLinkerArgs(spec, producer, scope, stdlibPath))
        }

        // Check system stdlib option.
        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx", toolchain: core.toolchainRegistry.defaultToolchain)
            let stdlibPath = swiftcPath.dirname.dirname.join("lib/swift/macosx")
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftcPath.str)
            table.push(BuiltinMacros.SWIFT_STDLIB, literal: "swiftCore")
            table.push(BuiltinMacros.SWIFT_FORCE_SYSTEM_LINK_STDLIB, literal: true)
            table.push(BuiltinMacros.PLATFORM_NAME, literal: "macosx")
            let scope = MacroEvaluationScope(table: table)
            let delegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(), fs: localFS)
            let optionContext = await spec.discoveredCommandLineToolSpecInfo(producer, scope, delegate)
            try await #expect(spec.computeAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: [], optionContext: optionContext, delegate: CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)).args == ([["-L/usr/lib/swift"]] + additionalSwiftLinkerArgs(spec, producer, scope, stdlibPath)))
        }
    }
}

@Suite fileprivate struct SwiftCompilerOutputParserTests: CoreBasedTests {
    private func makeTestParser() async throws -> (TestSwiftParserDelegate, SwiftCommandOutputParser) {
        let delegate = TestSwiftParserDelegate()
        let core = try await getCore()
        let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
        let parser = SwiftCommandOutputParser(workingDirectory: .root, variant: "VARIANT", arch: "ARCH", workspaceContext: workspaceContext, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate, progressReporter: nil)
        return (delegate, parser)
    }

    /// Create a string fragment for one individual message, containing the count and the message.
    private func makeMessageFragment(_ message: [String: any PropertyListItemConvertible]) throws -> ByteString {
        let stream = OutputByteStream()
        let fragment = try PropertyListItem(message).asJSONFragment()
        stream <<< String(fragment.count) <<< "\n"
        stream <<< fragment <<< "\n"
        return stream.bytes
    }

    private func makeTestParserWithMessages(_ messages: [[String: any PropertyListItemConvertible]]) async throws -> (TestSwiftParserDelegate, SwiftCommandOutputParser) {
        // Convert the messages into the expected stream.
        let stream = OutputByteStream()
        for message in messages {
            try stream <<< makeMessageFragment(message)
        }
        let (delegate, parser) = try await makeTestParser()
        parser.write(bytes: stream.bytes)
        parser.close(result: nil)
        return (delegate, parser)
    }

    /// Test the handling of the message chunks.
    @Test
    func messageChunking() async throws {
        do {
            let (delegate, parser) = try await makeTestParser()
            parser.write(bytes: "1\na\n2\nbc\n")
            parser.close(result: nil)
            #expect(delegate.events.count == 2)
            #expect(delegate.events[safe: 0]?.1 == "invalid Swift parseable output message (malformed JSON): `a\n`")
            #expect(delegate.events[safe: 1]?.1 == "invalid Swift parseable output message (malformed JSON): `bc\n`")
        }

        // Check handling of piecemeal delivery.
        do {
            let (delegate, parser) = try await makeTestParser()
            for byte in "1\na\n2\nbc\n".utf8 {
                parser.write(bytes: [byte])
            }
            parser.close(result: nil)
            #expect(delegate.events.count == 2)
            #expect(delegate.events[safe: 0]?.1 == "invalid Swift parseable output message (malformed JSON): `a\n`")
            #expect(delegate.events[safe: 1]?.1 == "invalid Swift parseable output message (malformed JSON): `bc\n`")
        }

        // Check that we don't make a mistake if we are missing only the trailing newline.
        do {
            let (delegate, parser) = try await makeTestParser()
            parser.write(bytes: "1\na")
            parser.write(bytes: "\n")
            parser.write(bytes: "2\nbc")
            parser.write(bytes: "\n")
            parser.close(result: nil)
            #expect(delegate.events.count == 2)
            #expect(delegate.events[safe: 0]?.1 == "invalid Swift parseable output message (malformed JSON): `a\n`")
            #expect(delegate.events[safe: 1]?.1 == "invalid Swift parseable output message (malformed JSON): `bc\n`")
        }
    }

    /// Test that we detect problems in the input (these would be malformed Swift responses).
    @Test
    func messageErrors() async throws {
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "foo": "bar" ],
                [ "kind": "began" ]])
            #expect(delegate.events.count == 2)
            XCTAssertMatch(delegate.events[safe: 0]?.1, .contains("missing kind"))
            XCTAssertMatch(delegate.events[safe: 1]?.1, .contains("missing name"))
        }

        // Missing 'pid' is an error.
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began",
                  "name": "compile" ],
                [ "kind": "finished",
                  "name": "compile" ]])
            #expect(delegate.events.count == 2)
            XCTAssertMatch(delegate.events[safe: 0]?.1, .contains("missing pid"))
            XCTAssertMatch(delegate.events[safe: 1]?.1, .contains("missing pid"))
        }

        // Duplicate 'pid' is an error.
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began",
                  "name": "compile",
                  "pid": 1,
                  "command": "foo"],
                [ "kind": "began",
                  "name": "compile",
                  "pid": 1,
                  "command": "foo"]])
            #expect(delegate.events.count == 2)
            // Check we still start the subtask.
            #expect(delegate.events[safe: 0]?.0 == "startSubtask")
            #expect(delegate.events[safe: 1]?.0 == "error")
            XCTAssertMatch(delegate.events[safe: 1]?.1, .contains("invalid pid 1 (already in use)"))
            // FIXME: We need to get a close subtask message here.
        }

        // Bogus 'pid' in 'finished' is an error.
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "finished",
                  "name": "compile",
                  "pid": 1 ]])
            #expect(delegate.events.count == 1)
            XCTAssertMatch(delegate.events[safe: 0]?.1, .contains("invalid pid (no subtask record)"))
        }
    }

    /// Check that we ignore unexpected output from the compiler.
    ///
    /// Currently, swiftc sometimes will write non-parsable output when the compiler crashes, for example.
    @Test
    func unexpectedOutput() async throws {
        do {
            let stream = OutputByteStream()
            try stream <<< makeMessageFragment([
                "kind": "began",
                "name": "compile",
                "pid": 1,
                "command": "foo"
            ])
            try stream <<< makeMessageFragment([
                "kind": "signalled",
                "name": "compile",
                "pid": 1,
                "output": "bla bla bla",
                "error-message": "Segmentation fault: 11"
            ])
            // Check two bogus messages in the middle.
            stream <<< "<unknown>:0: error: unable to execute command: Segmentation fault: 11\n"
            stream <<< "152 not a message cause it ain't got no newline at the front\n"
            try stream <<< makeMessageFragment([
                "kind": "began",
                "name": "compile",
                "pid": 2,
                "command": "foo"
            ])
            try stream <<< makeMessageFragment([
                "kind": "finished",
                "name": "compile",
                "pid": 2,
                "output": "bla bla bla",
                "exit-status": 1
            ])

            let (delegate, parser) = try await makeTestParser()
            parser.write(bytes: stream.bytes)
            parser.close(result: nil)
            #expect(delegate.events.count == 4)
            #expect(delegate.events[safe: 0]?.0 == "startSubtask")
            #expect(delegate.events[safe: 0]?.1 == "1")
            #expect(delegate.events[safe: 1]?.0 == "output")
            XCTAssertMatch(delegate.events[safe: 1]?.1, .contains("unable to execute"))
            #expect(delegate.events[safe: 2]?.0 == "output")
            XCTAssertMatch(delegate.events[safe: 2]?.1, .contains("not a message"))
            #expect(delegate.events[safe: 3]?.0 == "startSubtask")
            #expect(delegate.events[safe: 3]?.1 == "2")
        }
    }

    /// Check normal operational messages
    @Test
    func messageBehaviors() async throws {
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began",
                  "name": "compile",
                  "pid": 1,
                  "inputs": [Path.root.join("path/to/foo with space.swift").str, "not swift.pch"],
                  "command": "foo" ],
                [ "kind": "finished",
                  "name": "compile",
                  "inputs": ["foo.swift"],
                  "pid": 1,
                  "exit-status": 0,
                  "output": "foobar"],
                [ "kind": "skipped",
                  "name": "compile",
                  "inputs": ["bar.swift"],
                  "command": "foo" ]])
            #expect(delegate.events.count == 2)
            #expect(delegate.events[safe: 0]?.0 == "startSubtask")
            #expect(delegate.subtasks.count == 1)
            #expect(delegate.subtasks[safe: 0]?.name == "CompileSwift VARIANT ARCH \(Path.root.join("path/to/foo with space.swift").str.quotedDescription)")
            #expect(delegate.subtasks[safe: 0]?.interestingPath == Path.root.join("path/to/foo with space.swift"))
            #expect(delegate.subtasks[safe: 0]?.delegate.events.count == 2)
            #expect(delegate.subtasks[safe: 0]?.delegate.events[safe: 0]?.0 == "output")
            #expect(delegate.subtasks[safe: 0]?.delegate.events[safe: 0]?.1 == "foobar")
            #expect(delegate.subtasks[safe: 0]?.delegate.events[safe: 1]?.0 == "taskCompleted")
            #expect(delegate.subtasks[safe: 0]?.delegate.events[safe: 1]?.1 == "exitStatus: exited with status 0")
            #expect(delegate.events[safe: 1]?.0 == "skippedSubtask")

            let expectedSignature: ByteString = {
                let md5 = InsecureHashContext()
                md5.add(string: "CompileSwift VARIANT ARCH bar.swift")
                return md5.signature
            }()
            #expect(delegate.events[safe: 1]?.1 == expectedSignature.asString)
        }
    }

    // Check that an appropriate subtask title is generated when a compile job
    // with multiple inputs is run.
    @Test
    func multipleInputSubtaskTitle() async throws {
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began",
                  "name": "compile",
                  "pid": 1,
                  "inputs": [Path.root.join("path/to/a.swift").str]]
            ])
            #expect(delegate.subtasks[safe: 0]?.name == "CompileSwift VARIANT ARCH \(Path.root.join("path/to/a.swift").str.quotedDescription)")
            #expect(delegate.subtasks[safe: 0]?.executionDescription == "Compile a.swift (ARCH)")
            #expect(delegate.subtasks[safe: 0]?.interestingPath == Path.root.join("path/to/a.swift"))
        }
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began",
                  "name": "compile",
                  "pid": 1,
                  "inputs": [
                    Path.root.join("path/to/a.swift").str,
                    Path.root.join("path/to/b.swift").str
                  ]]
            ])
            #expect(delegate.subtasks[safe: 0]?.name == "CompileSwift VARIANT ARCH")
            #expect(delegate.subtasks[safe: 0]?.executionDescription == "Compile 2 Swift source files (ARCH)")
            #expect(delegate.subtasks[safe: 0]?.interestingPath == nil)
        }
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began",
                  "name": "compile",
                  "pid": 1,
                  "inputs": [
                    Path.root.join("path/to/a.swift").str,
                    Path.root.join("path/to/b.swift").str,
                    Path.root.join("path/to/c.swift").str
                  ]]
            ])
            #expect(delegate.subtasks[safe: 0]?.name == "CompileSwift VARIANT ARCH")
            #expect(delegate.subtasks[safe: 0]?.executionDescription == "Compile 3 Swift source files (ARCH)")
            #expect(delegate.subtasks[safe: 0]?.interestingPath == nil)
        }
    }

    @Test
    func executionDescription() async throws {
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began", "name": "compile", "pid": 1, "inputs": ["/tmp/file.swift"]],
                [ "kind": "began", "name": "compile", "pid": 2, "inputs": ["/tmp/file1.swift", "/tmp/file2.swift"]],
                [ "kind": "began", "name": "backend", "pid": 3, "inputs": ["/tmp/file.swift"]],
                [ "kind": "began", "name": "backend", "pid": 4, "inputs": ["/tmp/file1.swift", "/tmp/file2.swift"]],
                [ "kind": "began", "name": "merge-module", "pid": 5, "inputs": ["/tmp/file.swift"]],
                [ "kind": "began", "name": "merge-module", "pid": 6, "inputs": ["/tmp/file1.swift", "/tmp/file2.swift"]],
                [ "kind": "began", "name": "link", "pid": 7],
                [ "kind": "began", "name": "generate-pch", "pid": 8, "inputs": ["/tmp/file.swift"]],
                [ "kind": "began", "name": "generate-pch", "pid": 9, "inputs": ["/tmp/file1.swift", "/tmp/file2.swift"]],
                [ "kind": "began", "name": "generate-dsym", "pid": 10],
                [ "kind": "began", "name": "emit-module", "pid": 11, "inputs": ["/tmp/file1.swift"]],
                [ "kind": "began", "name": "emit-module", "pid": 12, "inputs": ["/tmp/file1.swift", "/tmp/file2.swift"]],
                [ "kind": "began", "name": "verify-module-interface", "pid": 13, "inputs": ["/tmp/file1.swiftinterface"]],
                [ "kind": "began", "name": "verify-module-interface", "pid": 14, "inputs": ["/tmp/file1.swiftinterface", "/tmp/file2.swiftinterface"]],
                [ "kind": "began", "name": "verify-module-interface", "pid": 15, "inputs": ["/tmp/file1.swiftinterface", "/tmp/file2.swiftinterface"]],
                [ "kind": "began", "name": "generate-pcm", "pid": 16, "inputs": ["/tmp/file.modulemap"]],
            ])

            #expect(delegate.subtasks.count == 16)

            let expectedExecDescriptions = [
                "Compile file.swift (ARCH)",
                "Compile 2 Swift source files (ARCH)",
                "Code Generation file.swift (ARCH)",
                "Code Generation for Swift source files (ARCH)",
                "Merge file.swift (ARCH)",
                "Merge swiftmodule (ARCH)",
                "Link (ARCH)",
                "Precompile Bridging Header file.swift (ARCH)",
                "Precompile bridging header (ARCH)",
                "Generate dSYM (ARCH)",
                "Emit Swift module (ARCH)",
                "Emit Swift module (ARCH)",
                "Verify file1.swiftinterface (ARCH)",
                "Verify swiftinterface (ARCH)",
                "Verify swiftinterface (ARCH)",
                "Compile Clang module file.modulemap (ARCH)"
            ]

            for (expectedExecDesc, subtask) in zip(expectedExecDescriptions, delegate.subtasks) {
                #expect(subtask.executionDescription == expectedExecDesc)
            }
        }
    }

    // Check that providing multiple .dia output files populates the serializedDiagnosticsPaths
    // field of the subtask.
    @Test
    func multipleDiagnosticOutputSubtask() async throws {
        do {
            let (delegate, _) = try await makeTestParserWithMessages([
                [ "kind": "began",
                  "name": "compile",
                  "pid": 1,
                  "inputs": ["/path/to/a.swift", "/path/to/b.swift"],
                  "outputs": [
                    ["type": "object",
                     "path": "/path/to/a.o"],
                    ["type": "object",
                     "path": "/path/to/b.o"],
                    ["type": "diagnostics",
                     "path": "/path/to/a.dia"],
                    ["type": "diagnostics",
                     "path": "/path/to/b.dia"]
                  ]
                ]
            ])
            #expect(delegate.subtasks[safe: 0]?.serializedDiagnosticsPaths == [Path("/path/to/a.dia"),
                                                                               Path("/path/to/b.dia")])
        }
    }
}
