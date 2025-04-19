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

import Testing
import SWBTestSupport
import SWBUtil

@Suite(.requireHostOS(.windows))
fileprivate struct PathWindowsTests {
    @Test func testCanonicalPathRepresentation_deviceFiles() throws {
        #expect(try "NUL".canonicalPathRepresentation == "\\\\.\\NUL")
        #expect(try Path("NUL").canonicalPathRepresentation == "\\\\.\\NUL")

        #expect(try "\\\\.\\NUL".canonicalPathRepresentation == "\\\\.\\NUL")

        // System.FilePath appends a trailing slash to fully qualified device file names
        withKnownIssue { () throws -> () in
            #expect(try Path("\\\\.\\NUL").canonicalPathRepresentation == "\\\\.\\NUL")
        }
    }

    @Test func testCanonicalPathRepresentation_driveLetters() throws {
        #expect(try Path("C:/").canonicalPathRepresentation == "C:\\")
        #expect(try Path("c:/").canonicalPathRepresentation == "c:\\")

        #expect(try Path("\\\\?\\C:/").canonicalPathRepresentation == "C:\\")
        #expect(try Path("\\\\?\\c:/").canonicalPathRepresentation == "c:\\")
    }

    @Test func testCanonicalPathRepresentation_absolute() throws {
        #expect(try Path("C:" + String(repeating: "/foo/bar/baz", count: 21)).canonicalPathRepresentation == "C:" + String(repeating: "\\foo\\bar\\baz", count: 21))
        #expect(try Path("C:" + String(repeating: "/foo/bar/baz", count: 22)).canonicalPathRepresentation == "\\\\?\\C:" + String(repeating: "\\foo\\bar\\baz", count: 22))
    }

    @Test func testCanonicalPathRepresentation_relative() throws {
        let root = Path.root.str.dropLast()
        #expect(try Path(String(repeating: "/foo/bar/baz", count: 21)).canonicalPathRepresentation == root + String(repeating: "\\foo\\bar\\baz", count: 21))
        #expect(try Path(String(repeating: "/foo/bar/baz", count: 22)).canonicalPathRepresentation == "\\\\?\\" + root + String(repeating: "\\foo\\bar\\baz", count: 22))
    }

    @Test func testCanonicalPathRepresentation_driveRelative() throws {
        let current = Path.currentDirectory

        // Ensure the output path will be < 260 characters so we can assert it's not prefixed with \\?\
        let chunks = (260 - current.str.count) / "foo/bar/baz/".count
        #expect(current.str.count < 248 && chunks > 0, "The current directory is too long for this test.")

        #expect(try Path(current.str.prefix(2) + String(repeating: "foo/bar/baz/", count: chunks)).canonicalPathRepresentation == current.join(String(repeating: "\\foo\\bar\\baz", count: chunks)).str)
        #expect(try Path(current.str.prefix(2) + String(repeating: "foo/bar/baz/", count: 22)).canonicalPathRepresentation == "\\\\?\\" + current.join(String(repeating: "\\foo\\bar\\baz", count: 22)).str)
    }
}

fileprivate extension String {
    var canonicalPathRepresentation: String {
        get throws {
            #if os(Windows)
            return try withCString(encodedAs: UTF16.self) { platformPath in
                return try platformPath.withCanonicalPathRepresentation { canonicalPath in
                    return String(decodingCString: canonicalPath, as: UTF16.self)
                }
            }
            #else
            return self
            #endif
        }
    }
}

fileprivate extension Path {
    var canonicalPathRepresentation: String {
        get throws {
            #if os(Windows)
            return try withPlatformString { platformPath in
                return try platformPath.withCanonicalPathRepresentation { canonicalPath in
                    return String(decodingCString: canonicalPath, as: UTF16.self)
                }
            }
            #else
            return str
            #endif
        }
    }
}
