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
import SWBUtil
import Testing

@Suite fileprivate struct TAPIFileListTests {
    @Test
    func basics() throws {
        #expect(ByteString(try TAPIFileList(version: .v1, headers: []).asBytes()) == """
{
  "headers" : [

  ],
  "version" : "1"
}
""")

        #expect(ByteString(try TAPIFileList(version: .v2, headers: []).asBytes()) == """
{
  "headers" : [

  ],
  "version" : "2"
}
""")

        let listNoProject = try TAPIFileList(version: .v1, headers: [
            (.public, Path.root.join("usr/include/public.h").str),
            (.private, Path.root.join("usr/local/include/private.h").str),
        ])
        #expect(ByteString(try listNoProject.asBytes()) == """
{
  "headers" : [
    {
      "path" : "\(Path.root.join("usr/include/public.h").str.escapedForJSON)",
      "type" : "public"
    },
    {
      "path" : "\(Path.root.join("usr/local/include/private.h").str.escapedForJSON)",
      "type" : "private"
    }
  ],
  "version" : "1"
}
""")
    }

    /// Tests that file lists are serialized with their headers in the same order as they are given.
    @Test
    func preserveDeclarationOrder() throws {
        let list = try TAPIFileList(version: .v2, headers: [
            (.project, Path.root.join("foo/car").str),
            (.public, Path.root.join("foo/bar").str),
            (.private, Path.root.join("foo/aar").str),
        ])
        #expect(ByteString(try list.asBytes()) == """
{
  "headers" : [
    {
      "path" : "\(Path.root.join("foo/car").str.escapedForJSON)",
      "type" : "project"
    },
    {
      "path" : "\(Path.root.join("foo/bar").str.escapedForJSON)",
      "type" : "public"
    },
    {
      "path" : "\(Path.root.join("foo/aar").str.escapedForJSON)",
      "type" : "private"
    }
  ],
  "version" : "2"
}
""")
    }

    @Test
    func errorHandling() throws {
        #expect {
            try TAPIFileList(version: .v1, headers: [
                (.public, Path.root.join("usr/include/public.h").str),
                (.private, Path.root.join("usr/local/include/private.h").str),
                (.project, Path.root.join("Users/$USER/include/project.h").str),
            ])
        } throws: { error in
            error as? TAPIFileListError == TAPIFileListError.unsupportedHeaderVisibility
        }

        // OK in v2
        let _ = try TAPIFileList(version: .v2, headers: [
            (.public, Path.root.join("usr/include/public.h").str),
            (.private, Path.root.join("usr/local/include/private.h").str),
            (.project, Path.root.join("Users/$USER/include/project.h").str),
        ])

        // Same path with different visibilities is an error
        #expect {
            try TAPIFileList(version: .v2, headers: [
                (.public, Path.root.join("usr/include/public.h").str),
                (.private, Path.root.join("usr/include/public.h").str),
                (.private, Path.root.join("usr/include/private.h").str),
                (.project, Path.root.join("Users/$USER/include/project.h").str),
            ])
        } throws: { error in
            error as? TAPIFileListError == TAPIFileListError.duplicateEntry(path: Path.root.join("usr/include/public.h").str, visibilities: Set([.public, .private]))
        }

        // These have set semantics; duplicate entries aren't a problem if they aren't ambiguous
        let _ = try TAPIFileList(version: .v2, headers: [
            (.public, Path.root.join("usr/include/public.h").str),
            (.public, Path.root.join("usr/include/public.h").str),
            (.private, Path.root.join("usr/local/include/private.h").str),
            (.project, Path.root.join("Users/$USER/include/project.h").str),
        ])
    }

    @Test
    func errorStrings() throws {
        #expect(TAPIFileListError.unsupportedHeaderVisibility.description == "Project headers are not supported in this version of TAPI")
        #expect(TAPIFileListError.duplicateEntry(path: "/foo.h", visibilities: [.public, .private, .project]).description == "Ambiguous visibility for TAPI file list header at '/foo.h': private, project, public")
    }

    @Test
    func versioning() throws {
        #expect(try TAPIFileList.FormatVersion.v1.requiredTAPIVersion == FuzzyVersion("0")) // v1 supported since "forever"
        #expect(try TAPIFileList.FormatVersion.v2.requiredTAPIVersion == FuzzyVersion("1100.*.2.1"))

        #expect(TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: Version(1100, 0, 2, 1)) == .v2)
        #expect(TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: Version(1100, 2, 2, 1)) == .v2)
        #expect(TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: Version(1100, 0, 3)) == .v2)
        #expect(TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: Version(1100, 3)) == .v1)
        #expect(TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: Version(1200)) == .v2)
        #expect(TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: Version(1000, 3)) == .v1)
        #expect(TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: Version(1000, 0, 2, 1)) == .v1)
    }
}
