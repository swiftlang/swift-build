//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct LinkerTaskActionTests {
    private let format: ResponseFileFormat = .unixShellQuotedSpaceSeparated

    private func action() -> LinkerTaskAction {
        LinkerTaskAction(expandResponseFiles: false, responseFileFormat: format, extractArchiveInputs: false)
    }

    private func writeLinkerArgsResp(_ fs: any FSProxy, _ path: Path, astPaths: [String]) throws {
        let args = astPaths.flatMap { ["-Xlinker", "-add_ast_path", "-Xlinker", $0] }
        try fs.createDirectory(path.dirname, recursive: true)
        try fs.write(path, contents: ByteString(encodingAsUTF8: ResponseFiles.responseFileContents(args: args, format: format)))
    }

    private func astPaths(in commandLine: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < commandLine.count {
            if i + 3 < commandLine.count, commandLine[i] == "-Xlinker", commandLine[i + 1] == "-add_ast_path", commandLine[i + 2] == "-Xlinker" {
                result.append(commandLine[i + 3])
                i += 4
            } else {
                i += 1
            }
        }
        return result
    }

    @Test
    func deduplicatesAddASTPathsAcrossResponseFiles() throws {
        let fs = MockExecutionDelegate().fs
        let respA = Path.root.join("mods").join("A-linker-args.resp")
        let respB = Path.root.join("mods").join("B-linker-args.resp")
        try writeLinkerArgsResp(fs, respA, astPaths: ["/mods/A.swiftmodule", "/a b/Shared.swiftmodule"])
        try writeLinkerArgsResp(fs, respB, astPaths: ["/mods/B.swiftmodule", "/a b/Shared.swiftmodule"])

        let commandLine = [
            "clang",
            "-filelist", "/objs.txt",
            "-Xlinker", "-add_ast_path", "-Xlinker", "/mods/A.swiftmodule",
            "@\(respA.str)",
            "@\(respB.str)",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path/Frameworks",
            "@/nonexistent/common-args.resp",
            "-o", "/out",
        ]

        let result = action().deduplicatingSwiftASTPaths(commandLine, fileSystem: fs, workingDirectory: Path.root)

        // Each distinct AST path appears exactly once.
        #expect(astPaths(in: result) == ["/mods/A.swiftmodule", "/a b/Shared.swiftmodule", "/mods/B.swiftmodule"])
        #expect(!result.contains("@\(respA.str)"))
        #expect(!result.contains("@\(respB.str)"))
        // Non-AST arguments are preserved.
        #expect(result.contains("@loader_path/Frameworks"))
        #expect(result.contains("@/nonexistent/common-args.resp"))
        #expect(result.firstIndex(of: "-filelist").map { result[$0 + 1] } == "/objs.txt")
        #expect(result.last == "/out")
    }
}
