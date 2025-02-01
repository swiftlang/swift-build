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

@Suite fileprivate struct VFSTests {
    @Test
    func VFSSerialization() throws {
        let vfs = VFS()

        let pathsToMap: [(Path, Path)] = [
            (.root.join("tmp/A/Z/module.modulemap"), .root.join("tmp/module.modulemap")),
            (.root.join("tmp/A/Foo.h"), .root.join("tmp/Foo.h")),
            (.root.join("tmp/A/Bar.h"), .root.join("tmp/Bar.h")),
        ]
        for (path, target) in pathsToMap {
            vfs.addMapping(path, externalContents: target)
        }

        #expect(try vfs.toVFSOverlay().propertyListItem.asJSONFragment().asString == PropertyList.fromJSONData(ByteString("""
            {
              "version": 0,
              "case-sensitive": "false",
              "roots": [
                {
                  "type": "directory",
                  "name": "\(Path.root.join("tmp/A/Z").str.escapedForJSON)",
                  "contents": [
                    {
                      "type": "file",
                      "name": "module.modulemap",
                      "external-contents": "\(Path.root.join("tmp/module.modulemap").str.escapedForJSON)"
                    }
                  ]
                },
                {
                  "type": "directory",
                  "name": "\(Path.root.join("tmp/A").str.escapedForJSON)",
                  "contents": [
                    {
                      "type": "file",
                      "name": "Bar.h",
                      "external-contents": "\(Path.root.join("tmp/Bar.h").str.escapedForJSON)"
                    },
                    {
                      "type": "file",
                      "name": "Foo.h",
                      "external-contents": "\(Path.root.join("tmp/Foo.h").str.escapedForJSON)"
                    }
                  ]
                }
              ]
            }\n
            """)).asJSONFragment().asString)
    }
}
