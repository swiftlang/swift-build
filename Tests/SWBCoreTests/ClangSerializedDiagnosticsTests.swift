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

import SWBCore
import SWBTestSupport
import SWBUtil
import Testing

@Suite(.skipHostOS(.windows, "not yet working"))
fileprivate struct ClangSerializedDiagnosticsTests: CoreBasedTests {
    var libclangPath: String {
        get async throws {
            let core = try await Self.makeCore()
            let toolchain = try #require(core.toolchainRegistry.defaultToolchain)
            return try #require(toolchain.librarySearchPaths.findLibrary(operatingSystem: core.hostOperatingSystem, basename: "clang") ?? toolchain.fallbackLibrarySearchPaths.findLibrary(operatingSystem: core.hostOperatingSystem, basename: "clang")).str
        }
    }

    /// Test that Clang serialized diagnostics are supported.
    @Test
    func clangSerializedDiagnosticSupported() async throws {
        try await withTemporaryDirectory { tmpDir in
            let diagnosticsPath = tmpDir.join("foo.diag")
            _ = try? await runHostProcess(["clang", "-serialize-diagnostics", diagnosticsPath.str, "foo.c"], workingDirectory: tmpDir.str)

            let libclang = try #require(await Libclang(path: libclangPath))
            libclang.leak()
            let diagnostics = try libclang.loadDiagnostics(filePath: diagnosticsPath.str).map { Diagnostic($0, workingDirectory: tmpDir, appendToOutputStream: false) }
            #expect(!diagnostics.isEmpty)
        }
    }

    /// Test that Clang serialized diagnostics handle relative paths.
    @Test(.requireThreadSafeWorkingDirectory)
    func clangSerializedDiagnosticRelativePaths() async throws {
        try await withTemporaryDirectory { tmpDir in
            let diagnosticsPath = tmpDir.join("foo.diag")
            try localFS.createDirectory(tmpDir.join("other"), recursive: true)
            let hFilePath = tmpDir.join("other/foo.h")
            try localFS.write(hFilePath, contents: "static int foo() { return 0; }")
            try localFS.createDirectory(tmpDir.join("dir"), recursive: true)
            let cFilePath = tmpDir.join("dir/foo.c")
            try localFS.write(cFilePath, contents: "#include \"other/foo.h\"\nint main() { return 0; }")
            let taskWorkingDirectory = cFilePath.dirname
            _ = try? await runHostProcess(["clang", "-I../", "-Wall", "-serialize-diagnostics", diagnosticsPath.str, "foo.c"], workingDirectory: taskWorkingDirectory.str)
            
            let libclang = try #require(await Libclang(path: libclangPath))
            libclang.leak()
            
            // Ensure there's only one diagnostic and its path is relative.
            let clangDiagnostics = try libclang.loadDiagnostics(filePath: diagnosticsPath.str)
            #expect(clangDiagnostics.count == 1, Comment(rawValue: clangDiagnostics.description))
            #expect(clangDiagnostics.only?.fileName == "../other/foo.h")
            
            // Ensure there's only one diagnostic and its path has been made absolute.
            let diagnostics = clangDiagnostics.map { Diagnostic($0, workingDirectory: taskWorkingDirectory, appendToOutputStream: false) }
            #expect(diagnostics.count == 1)
            #expect(diagnostics.only?.location == Diagnostic.Location.path(hFilePath, line: 1, column: 12))
        }
    }

    /// Test some of the the details serialized diagnostics from Clang.
    @Test(.requireThreadSafeWorkingDirectory)
    func clangSerializedClangDiagnosticClangsDetails() async throws {
        try await withTemporaryDirectory { tmpDir in
            let diagnosticsPath = tmpDir.join("foo.diag")
            try localFS.createDirectory(tmpDir.join("other"), recursive: true)
            let hFilePath = tmpDir.join("other/foo.h")
            try localFS.write(hFilePath, contents: "static int foo() { return 0; }")
            try localFS.createDirectory(tmpDir.join("dir"), recursive: true)
            let cFilePath = tmpDir.join("dir/foo.c")
            try localFS.write(cFilePath, contents: "#include \"other/foo.h\"\nint main() { return 0; }")
            let taskWorkingDirectory = cFilePath.dirname
            _ = try? await runHostProcess(["clang", "-I../", "-Wall", "-serialize-diagnostics", diagnosticsPath.str, "foo.c"], workingDirectory: taskWorkingDirectory.str)

            let libclang = try #require(await Libclang(path: libclangPath))
            libclang.leak()

            // Ensure there's only one diagnostic and it has the appropriate option.
            let clangDiagnostics = try libclang.loadDiagnostics(filePath: diagnosticsPath.str)
            #expect(clangDiagnostics.count == 1, Comment(rawValue: clangDiagnostics.description))
            #expect(clangDiagnostics.only?.severity == .warning)
            #expect(clangDiagnostics.only?.text == "unused function 'foo'")
            #expect(clangDiagnostics.only?.optionName == "unused-function")
            #expect(clangDiagnostics.only?.line == 1)
        }
    }

    /// Test some of the the details serialized diagnostics from SwiftC.
    @Test(.requireThreadSafeWorkingDirectory)
    func clangSerializedSwiftDiagnosticsDetails() async throws {
        try await withTemporaryDirectory { tmpDir in
            try localFS.createDirectory(tmpDir.join("dir"), recursive: true)
            let swiftFilePath = tmpDir.join("dir/foo.swift")
            try localFS.write(swiftFilePath, contents: "#warning(\"custom warning\")")
            let taskWorkingDirectory = swiftFilePath.dirname
            let diagnosticsPath = taskWorkingDirectory.join("foo.dia")
            _ = try? await runHostProcess(["swiftc", "-c", "-serialize-diagnostics", "foo.swift"], workingDirectory: taskWorkingDirectory.str)

            let libclang = try #require(await Libclang(path: libclangPath))
            libclang.leak()

            // Ensure there's only one diagnostic and it has the appropriate option.
            let clangDiagnostics = try libclang.loadDiagnostics(filePath: diagnosticsPath.str)
            #expect(clangDiagnostics.count == 1, Comment(rawValue: clangDiagnostics.description))
            #expect(clangDiagnostics.only?.severity == .warning)
            #expect(clangDiagnostics.only?.text == "custom warning")
            #expect(clangDiagnostics.only?.optionName == nil)  // `swiftc` doesn't emit options yet
            #expect(clangDiagnostics.only?.line == 1)
        }
    }
}
