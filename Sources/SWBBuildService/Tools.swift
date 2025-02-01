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

import class Foundation.Bundle
import class Foundation.ProcessInfo

import SWBCore
import SWBUtil
import SWBTaskExecution

// MARK: Top-level Testing & Debugging Tools

/// Execute an internally defined "command line tool".
///
/// The output from the tool will be passed to the given handlers, and the tool result (success/failure) will be returned.
func executeInternalTool(core: Core, commandLine: [String], workingDirectory: Path, stdoutHandler: @escaping (String) -> Void, stderrHandler: @escaping (String) -> Void) async -> Bool {
    do {
        switch commandLine[0] {
        case "dumpMsgPack":
            let tool = MsgPackDumpTool(commandLine, workingDirectory: workingDirectory, stdoutHandler: stdoutHandler, stderrHandler: stderrHandler)
            return try tool.execute()

        case "headermap":
            let tool = HeadermapTool(commandLine, workingDirectory: workingDirectory, stdoutHandler: stdoutHandler, stderrHandler: stderrHandler)
            return try tool.execute()

        case "clang-scan":
            let tool = ClangScanTool(commandLine, workingDirectory: workingDirectory, stdoutHandler: stdoutHandler, stderrHandler: stderrHandler)
            return try tool.execute()

        case "serializedDiagnostics":
            let tool = SerializedDiagnosticsTool(commandLine, workingDirectory: workingDirectory, stdoutHandler: stdoutHandler, stderrHandler: stderrHandler)
            return try await tool.execute(core: core)

        case let program:
            stderrHandler("error: unknown internal tool `\(program)`\n")
            return false
        }
    } catch {
        stderrHandler("error: tool threw uncaught error: \(error)\n")
        return false
    }
}

/// Dump a MsgPack file (used for checking build description.
///
/// This will build using the given input specification (possibly multiple times) and check the result.
private class MsgPackDumpTool {
    /// The parsed command line options.
    struct Options {
        static func emitUsage(_ name: String, _ handler: @escaping (String) -> Void) {
            let stream = OutputByteStream()
            stream <<< "usage: \(name) --path path\n"
            handler(stream.bytes.asString)
        }

        /// The path to the file to dump.
        let path: Path

        init?(_ commandLine: AnySequence<String>, workingDirectory cwd: Path, stderrHandler: @escaping (String) -> Void) {
            var pathOpt: Path? = nil
            var hadErrors = false
            func error(_ message: String) {
                stderrHandler("error: \(message)\n")
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
            while let arg = generator.next() {
                switch arg {
                case "--help":
                    Options.emitUsage(programName, stderrHandler)
                    return nil

                case "--path":
                    guard let path = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    pathOpt = cwd.join(Path(path))

                default:
                    error("unrecognized argument: '\(arg)'")
                }
            }

            // Diagnose missing required arguments.
            guard let path = pathOpt else {
                error("no path given, --path is required")
                return nil
            }

            // Initialize contents.
            self.path = path

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                stderrHandler("\n")
                Options.emitUsage(programName, stderrHandler)
                return nil
            }
        }
    }

    let commandLine: [String]
    let workingDirectory: Path
    let stdoutHandler: (String) -> Void
    let stderrHandler: (String) -> Void
    var numErrors = 0

    init(_ commandLine: [String], workingDirectory: Path, stdoutHandler: @escaping (String) -> Void, stderrHandler: @escaping (String) -> Void) {
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.stdoutHandler = stdoutHandler
        self.stderrHandler = stderrHandler
    }

    func emitNote(_ message: String) {
        stdoutHandler("note: \(message)\n")
    }
    func emitWarning(_ message: String) {
        stdoutHandler("warning: \(message)\n")
    }
    func emitError(_ message: String) {
        stderrHandler("error: \(message)\n")
        numErrors += 1
    }

    /// Execute the tool.
    func execute() throws -> Bool {
        // Parse the command line arguments.
        guard let options = Options(AnySequence(commandLine), workingDirectory: workingDirectory, stderrHandler: stderrHandler) else {
            return false
        }

        // Read the file.
        let data = try localFS.read(options.path)

        emitNote("loaded \(data.count) bytes")

        let decoder = MsgPackDecoder(ArraySlice(data.bytes))

        // Consume all the objects in the file.
        enum DecoderItem {
            /// A dictionary with N elements remaining.
        case dict(count: Int, atKey: Bool)
            /// An array with N elements remaining.
        case array(count: Int)
        }
        var stack = [DecoderItem]()
        var indent: String {
            return String(repeating: " ", count: stack.count)
        }
        while decoder.consumedCount != data.count || !stack.isEmpty {
            // Check where we are in the object stack.
            if !stack.isEmpty {
                switch stack.removeLast() {
                case .dict(let n, let atKey):
                    // If we are at the last item, close the dictionary.
                    if n == 0, !atKey {
                        stdoutHandler("\(indent)},\n")
                        continue
                    }

                    // Otherwise, step to the next item.
                    if atKey {
                        stack.append(.dict(count: n, atKey: false))
                    } else {
                        stack.append(.dict(count: n - 1, atKey: true))
                    }
                case .array(let n):
                    // If we are at the last item, close the dictionary.
                    if n == 0 {
                        stdoutHandler("\(indent)],\n")
                        continue
                    }

                    // Otherwise, step to the next item.
                    stack.append(.array(count: n - 1))
                }
            }

            if decoder.consumedCount == data.count {
                continue // at EOF, go back through and finish the indenting
            }

            // Read the next item from the decoder.
            if let i = decoder.readInt64() {
                stdoutHandler("\(indent)\(i),\n")
            } else if let i = decoder.readUInt64() {
                stdoutHandler("\(indent)\(i),\n")
            } else if decoder.readNil() {
                stdoutHandler("\(indent)nil,\n")
            } else if let i = decoder.readBool() {
                stdoutHandler("\(indent)\(i),\n")
            } else if let i = decoder.readFloat32() {
                stdoutHandler("\(indent)\(i),\n")
            } else if let i = decoder.readFloat64() {
                stdoutHandler("\(indent)\(i),\n")
            } else if let i = decoder.readString() {
                stdoutHandler("\(indent)\(i),\n")
            } else if let i = decoder.readBinary() {
                stdoutHandler("\(indent)\(i.asReadableString()),\n")
            } else if let n = decoder.readBeginArray() {
                stdoutHandler("\(indent)[ # \(n) elements\n")
                stack.append(.array(count: n))
            } else if let n = decoder.readBeginMap() {
                stdoutHandler("\(indent){ # \(n) elements\n")
                stack.append(.dict(count: n, atKey: true))
            } else {
                emitError("unrecognized item in MsgPack sequence")
                break
            }
        }

        return numErrors == 0
    }
}


/// Utilities for working with headermaps.
private class HeadermapTool {
    /// The parsed command line options.
    struct Options {
        static func emitUsage(_ name: String, _ handler: @escaping (String) -> Void) {
            let stream = OutputByteStream()
            stream <<< "usage: \(name) --dump path\n"
            handler(stream.bytes.asString)
        }

        /// The path to the file to dump.
        let path: Path

        init?(_ commandLine: AnySequence<String>, workingDirectory cwd: Path, stderrHandler: @escaping (String) -> Void) {
            var pathOpt: Path? = nil
            var hadErrors = false
            func error(_ message: String) {
                stderrHandler("error: \(message)\n")
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
            while let arg = generator.next() {
                switch arg {
                case "--help":
                    Options.emitUsage(programName, stderrHandler)
                    return nil

                case "--dump":
                    guard let path = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    pathOpt = cwd.join(Path(path))

                default:
                    error("unrecognized argument: '\(arg)'")
                }
            }

            // Diagnose missing required arguments.
            if pathOpt == nil {
                pathOpt = Path("")
                error("no path specified")
            }

            // Initialize contents.
            self.path = pathOpt!

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                stderrHandler("\n")
                Options.emitUsage(programName, stderrHandler)
                return nil
            }
        }
    }

    let commandLine: [String]
    let workingDirectory: Path
    let stdoutHandler: (String) -> Void
    let stderrHandler: (String) -> Void
    var numErrors = 0

    init(_ commandLine: [String], workingDirectory: Path, stdoutHandler: @escaping (String) -> Void, stderrHandler: @escaping (String) -> Void) {
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.stdoutHandler = stdoutHandler
        self.stderrHandler = stderrHandler
    }

    func emitNote(_ message: String) {
        stdoutHandler("note: \(message)\n")
    }
    func emitWarning(_ message: String) {
        stdoutHandler("warning: \(message)\n")
    }
    func emitError(_ message: String) {
        stderrHandler("error: \(message)\n")
        numErrors += 1
    }

    /// Execute the tool.
    func execute() throws -> Bool {
        // Parse the command line arguments.
        guard let options = Options(AnySequence(commandLine), workingDirectory: workingDirectory, stderrHandler: stderrHandler) else {
            return false
        }

        // Read the file.
        let data: ByteString
        do {
            data = try localFS.read(options.path)
        } catch {
            emitError("unable to load headermap data: \(error)")
            return false
        }

        let hmap: Headermap
        do {
            hmap = try Headermap(bytes: data.bytes)
        } catch {
            emitError("unable to parse headermap contents: \(error)")
            return false
        }

        for entry in hmap {
            stdoutHandler("\(entry.0.asReadableString()) -> \(entry.1.asReadableString())\n")
        }

        return true
    }
}

/// Utilities for working with dependency scanner outputs.
private class ClangScanTool {
    /// The parsed command line options.
    struct Options {
        static func emitUsage(_ name: String, _ handler: @escaping (String) -> Void) {
            let stream = OutputByteStream()
            stream <<< "usage: \(name) --dump path\n"
            handler(stream.bytes.asString)
        }

        /// The path to the file to dump.
        let path: Path

        init?(_ commandLine: AnySequence<String>, workingDirectory cwd: Path, stderrHandler: @escaping (String) -> Void) {
            var pathOpt: Path? = nil
            var hadErrors = false
            func error(_ message: String) {
                stderrHandler("error: \(message)\n")
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
            while let arg = generator.next() {
                switch arg {
                case "--help":
                    Options.emitUsage(programName, stderrHandler)
                    return nil

                case "--dump":
                    guard let path = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    pathOpt = cwd.join(Path(path))

                default:
                    error("unrecognized argument: '\(arg)'")
                }
            }

            // Diagnose missing required arguments.
            if pathOpt == nil {
                pathOpt = Path("")
                error("no path specified")
            }

            // Initialize contents.
            self.path = pathOpt!

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                stderrHandler("\n")
                Options.emitUsage(programName, stderrHandler)
                return nil
            }
        }
    }

    let commandLine: [String]
    let workingDirectory: Path
    let stdoutHandler: (String) -> Void
    let stderrHandler: (String) -> Void
    var numErrors = 0

    init(_ commandLine: [String], workingDirectory: Path, stdoutHandler: @escaping (String) -> Void, stderrHandler: @escaping (String) -> Void) {
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.stdoutHandler = stdoutHandler
        self.stderrHandler = stderrHandler
    }

    func emitNote(_ message: String) {
        stdoutHandler("note: \(message)\n")
    }
    func emitWarning(_ message: String) {
        stdoutHandler("warning: \(message)\n")
    }
    func emitError(_ message: String) {
        stderrHandler("error: \(message)\n")
        numErrors += 1
    }

    /// Execute the tool.
    func execute() throws -> Bool {
        // Parse the command line arguments.
        guard let options = Options(AnySequence(commandLine), workingDirectory: workingDirectory, stderrHandler: stderrHandler) else {
            return false
        }

        // Read the file.
        let data: ByteString
        do {
            data = try localFS.read(options.path)
        } catch {
            emitError("unable to load headermap data: \(error)")
            return false
        }

        let scan: ClangModuleDependencyGraph.DependencyInfo
        do {
            let deserializer = MsgPackDeserializer(data)
            scan = try deserializer.deserialize()
        } catch {
            emitError("unable to parse scan contents: \(error)")
            return false
        }

        stdoutHandler("kind: \(scan.kind)\n")
        stdoutHandler("usesSerializedDiagnostics: \(scan.usesSerializedDiagnostics)\n")
        stdoutHandler("commands:\n")
        for command in scan.commands {
            stdoutHandler("\t\(command.cacheKey ?? "no cache key"): \(command.arguments.joined(separator: " "))\n")
        }
        stdoutHandler("files:\n")
        for file in scan.files {
            stdoutHandler("\t\(file.str)\n")
        }
        stdoutHandler("modules:\n")
        for module in scan.modules {
            stdoutHandler("\t\(module.str)\n")
        }

        return true
    }
}



private class SerializedDiagnosticsTool {
    /// The parsed command line options.
    struct Options {
        static func emitUsage(_ name: String, _ handler: @escaping (String) -> Void) {
            let stream = OutputByteStream()
            stream <<< "usage: \(name) --dump path\n"
            handler(stream.bytes.asString)
        }

        /// The path to the file to dump.
        let path: Path

        init?(_ commandLine: AnySequence<String>, workingDirectory cwd: Path, stderrHandler: @escaping (String) -> Void) {
            var pathOpt: Path? = nil
            var hadErrors = false
            func error(_ message: String) {
                stderrHandler("error: \(message)\n")
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
            while let arg = generator.next() {
                switch arg {
                case "--help":
                    Options.emitUsage(programName, stderrHandler)
                    return nil

                case "--dump":
                    guard let path = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    pathOpt = cwd.join(Path(path))

                default:
                    error("unrecognized argument: '\(arg)'")
                }
            }

            // Diagnose missing required arguments.
            if pathOpt == nil {
                pathOpt = Path("")
                error("no path specified")
            }

            // Initialize contents.
            self.path = pathOpt!

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                stderrHandler("\n")
                Options.emitUsage(programName, stderrHandler)
                return nil
            }
        }
    }

    let commandLine: [String]
    let workingDirectory: Path
    let stdoutHandler: (String) -> Void
    let stderrHandler: (String) -> Void
    var numErrors = 0

    init(_ commandLine: [String], workingDirectory: Path, stdoutHandler: @escaping (String) -> Void, stderrHandler: @escaping (String) -> Void) {
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.stdoutHandler = stdoutHandler
        self.stderrHandler = stderrHandler
    }

    func emitNote(_ message: String) {
        stdoutHandler("note: \(message)\n")
    }
    func emitWarning(_ message: String) {
        stdoutHandler("warning: \(message)\n")
    }
    func emitError(_ message: String) {
        stderrHandler("error: \(message)\n")
        numErrors += 1
    }

    /// Execute the tool.
    func execute(core: Core) async throws -> Bool {
        // Parse the command line arguments.
        guard let options = Options(AnySequence(commandLine), workingDirectory: workingDirectory, stderrHandler: stderrHandler) else {
            return false
        }

        let toolchain = core.toolchainRegistry.defaultToolchain
        guard let libclangPath = toolchain?.librarySearchPaths.findLibrary(operatingSystem: core.hostOperatingSystem, basename: "clang") ?? toolchain?.fallbackLibrarySearchPaths.findLibrary(operatingSystem: core.hostOperatingSystem, basename: "clang") else {
            throw StubError.error("unable to find libclang")
        }

        guard let libclang = Libclang(path: libclangPath.str) else {
            emitError("unable to open libclang: \(libclangPath)")
            return false
        }
        defer {
            libclang.leak()
        }

        let diagnostics: [ClangDiagnostic]
        do {
            func printDiagnostic(_ diagnostic: Diagnostic, indentationLevel: Int = 0) {
                for _ in 0..<indentationLevel {
                    stdoutHandler("\t")
                }
                stdoutHandler(diagnostic.formatLocalizedDescription(.debug))
                stdoutHandler("\n")
            }
            diagnostics = try libclang.loadDiagnostics(filePath: options.path.str)
            for diagnostic in diagnostics.map({ Diagnostic($0, workingDirectory: workingDirectory, appendToOutputStream: false) }) {
                printDiagnostic(diagnostic)
                for childDiagnostic in diagnostic.childDiagnostics {
                    printDiagnostic(childDiagnostic, indentationLevel: 1)
                }
            }
        } catch {
            emitError("unable to parse serialized diagnostics file: \(error)")
            return false
        }

        return true
    }
}
