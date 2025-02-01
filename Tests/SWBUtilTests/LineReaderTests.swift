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

@Suite fileprivate struct LineReaderTests {
    @Test
    func lineReader() throws {
        try withTemporaryDirectory { tmpdir in
            let path = tmpdir.join("test.txt")
            try localFS.write(path, contents: "hello\nworld\n\n")

            let lineReader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str))
            #expect(try lineReader.readLine() == "hello")
            #expect(try lineReader.readLine() == "world")
            #expect(try lineReader.readLine() == "")
            #expect(try lineReader.readLine() == nil)
        }
    }

    @Test
    func lineReaderLongLines() throws {
        try withTemporaryDirectory { tmpdir in
            let path = tmpdir.join("test.txt")
            try localFS.write(path, contents: "hello\nworld\n\n")

            let lineReader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str), bufferSize: 2)
            #expect(try lineReader.readLine() == "hello")
            #expect(try lineReader.readLine() == "world")
            #expect(try lineReader.readLine() == "")
            #expect(try lineReader.readLine() == nil)
        }
    }

    @Test
    func lineReaderCustomDelimiter() throws {
        try withTemporaryDirectory { tmpdir in
            let path = tmpdir.join("test.txt")
            try localFS.write(path, contents: "hello\r\nworld\r\n\r\n")

            let lineReader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str), delimiter: "\r\n")
            #expect(try lineReader.readLine() == "hello")
            #expect(try lineReader.readLine() == "world")
            #expect(try lineReader.readLine() == "")
            #expect(try lineReader.readLine() == nil)
        }
    }

    @Test
    func lineReaderRewind() throws {
        try withTemporaryDirectory { tmpdir in
            let path = tmpdir.join("test.txt")
            try localFS.write(path, contents: "hello\nworld\n\n")

            let lineReader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str))
            #expect(try lineReader.readLine() == "hello")
            #expect(try lineReader.readLine() == "world")
            #expect(try lineReader.readLine() == "")
            #expect(try lineReader.readLine() == nil)

            try lineReader.rewind()

            #expect(try lineReader.readLine() == "hello")
            #expect(try lineReader.readLine() == "world")
            #expect(try lineReader.readLine() == "")
            #expect(try lineReader.readLine() == nil)

            // At EOF, returns nil
            #expect(try lineReader.readLine() == nil)
        }
    }

    @Test
    func emptyFile() throws {
        try withTemporaryDirectory { tmpdir in
            let path = tmpdir.join("test.txt")
            try localFS.write(path, contents: "")

            let lineReader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str))
            #expect(try lineReader.readLine() == nil)
        }
    }

    @Test
    func delimiterNotPresent() throws {
        try withTemporaryDirectory { tmpdir in
            let path = tmpdir.join("test.txt")
            try localFS.write(path, contents: "helloworld")

            let lineReader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str), bufferSize: 2)
            #expect(try lineReader.readLine() == "helloworld")
            #expect(try lineReader.readLine() == nil)
        }
    }

    @Test
    func exactBufferSize() throws {
        try withTemporaryDirectory { tmpdir in
            let path = tmpdir.join("test.txt")
            try localFS.write(path, contents: "hello")

            let lineReader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str), bufferSize: 5)
            #expect(try lineReader.readLine() == "hello")
            #expect(try lineReader.readLine() == nil)
        }
    }
}
