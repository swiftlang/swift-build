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

@Suite fileprivate struct ResponseFileTests {
    @Test
    func responseFileContent() throws {
        try assertRoundTrip(args: ["foo", "bar"], "foo bar")
        try assertRoundTrip(args: ["foo bar"], "'foo bar'")
        try assertRoundTrip(args: ["foo bar", "baz"], "'foo bar' baz")
        try assertRoundTrip(args: ["/this/is/a/path", "-bar"], "/this/is/a/path -bar")

        try assertRoundTrip(args: [#"'"#], #"\'"#)
        try assertRoundTrip(args: [#"""#], #"'"'"#)
        try assertRoundTrip(args: [#" a b '"#], #"' a b '\'"#)
        try assertRoundTrip(args: [#"' a b "#], #"\'' a b '"#)
        try assertRoundTrip(args: [#"start foo "bar baz's slash\" end"#], #"'start foo "bar baz'\''s slash\" end'"#)
    }

    @Test
    func responseFileExpansion() throws {
        try withTemporaryDirectory { tmpDir in
            try localFS.write(tmpDir.join("a.resp"), contents: "-foo -bar -baz")
            try localFS.write(tmpDir.join("b.resp"), contents: "-b @a.resp")
            try localFS.write(tmpDir.join("c.resp"), contents: "-foo @c.resp")
            try localFS.write(tmpDir.join("d.resp"), contents: """
            // comment
            -foo -bar -baz
            // comment two
            -path '/path/with space' @b.resp
            """)
            try #expect(ResponseFiles.expandResponseFiles(["-first", "@a.resp", "-last"], fileSystem: localFS, relativeTo: tmpDir) == ["-first", "-foo", "-bar", "-baz", "-last"])
            try #expect(ResponseFiles.expandResponseFiles(["-first", "@b.resp", "-last"], fileSystem: localFS, relativeTo: tmpDir) == ["-first", "-b", "-foo", "-bar", "-baz", "-last"])
            #expect(throws: (any Error).self) {
                try ResponseFiles.expandResponseFiles(["-first", "@c.resp", "-last"], fileSystem: localFS, relativeTo: tmpDir)
            }
            try #expect(ResponseFiles.expandResponseFiles(["-first", "@d.resp", "-last"], fileSystem: localFS, relativeTo: tmpDir) == ["-first", "-foo", "-bar", "-baz", "-path", "/path/with space", "-b", "-foo", "-bar", "-baz", "-last"])
        }
    }

    private func assertRoundTrip(args: [String], _ contents: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actualContents = ResponseFiles.responseFileContents(args: args)
        #expect(actualContents == contents, sourceLocation: sourceLocation)

        let fs = PseudoFS()
        try fs.write(Path.root.join("a.resp"), contents: ByteString(encodingAsUTF8: actualContents))
        try #expect(ResponseFiles.expandResponseFiles(["@a.resp"], fileSystem: fs, relativeTo: .root) == args, sourceLocation: sourceLocation)
    }
}
