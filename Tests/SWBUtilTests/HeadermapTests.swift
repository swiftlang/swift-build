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

extension Headermap {
    /// Helper for getting a readable list of bindings.
    var debugBindings: [String] {
        return self.map({ "\($0.asReadableString()) -> \($1.asReadableString())" }).sorted(by: { $0.lowercased() < $1.lowercased() })
    }
}

@Suite fileprivate struct HeadermapTests {
    @Test
    func writeMinimalHmap() {
        let hmap = Headermap(capacity: 1)

        // Manually construct the expected output, so we have at least one test based on the fixed output.
        var expected = [UInt8]()
        expected += [112, 97, 109, 104]                  // magic
        expected += [1, 0]                               // version
        expected += [0, 0]                               // reserved
        expected += [36, 0, 0, 0]                        // string table offset (== header size (24) + bucket size (12) * bucket count (1))
        expected += [0, 0, 0, 0]                         // num entries
        expected += [1, 0, 0, 0]                         // num buckets
        expected += [0, 0, 0, 0]                         // max value length
        expected += [UInt8](repeating: 0, count: 12) // bucket
        expected += [0]                                  // string table
        #expect(hmap.toBytes() == ByteString(expected))
    }

    @Test
    func readMinimalHmap() throws {
        var input = [UInt8]()
        input += [112, 97, 109, 104]                  // magic
        input += [1, 0]                               // version
        input += [0, 0]                               // reserved
        input += [72, 0, 0, 0]                        // string table offset (== header size (24) + bucket size (12) * bucket count (4))
        input += [1, 0, 0, 0]                         // num entries
        input += [4, 0, 0, 0]                         // num buckets
        input += [8, 0, 0, 0]                         // max value length
        input += [UInt8](repeating: 0, count: 12) // bucket
        input += [UInt8](repeating: 0, count: 12) // bucket
        input += [UInt8](repeating: 0, count: 12) // bucket
        input += [1, 0, 0, 0]                         // bucket (key index)
        input += [5, 0, 0, 0]                         // bucket (prefix index)
        input += [1, 0, 0, 0]                         // bucket (suffix index)
        input += [0]                                  // string-table (offset: 0, "")
        input += [UInt8]("a.h".utf8) + [0]            // string-table (offset: 1, "")
        input += [UInt8]("/tmp/".utf8) + [0]          // string-table (offset: 5, "")
        let hmap = try Headermap(bytes: input)
        #expect(hmap.debugBindings == ["a.h -> /tmp/a.h"])
    }

    @Test
    func insert() {
        var hmap = Headermap(capacity: 1)
        hmap.insert(Path("a.h"), value: Path.root.join("tmp/a.h"))
        #expect(hmap.debugBindings == ["a.h -> \(Path.root.join("tmp/a.h").str)"])
        hmap.insert(Path("b.h"), value: Path.root.join("tmp/b.h"))
        #expect(hmap.debugBindings == ["a.h -> \(Path.root.join("tmp/a.h").str)", "b.h -> \(Path.root.join("tmp/b.h").str)"])
        hmap.insert(Path("c.h"), value: Path.root.join("tmp/c.h"))
        #expect(hmap.debugBindings == ["a.h -> \(Path.root.join("tmp/a.h").str)", "b.h -> \(Path.root.join("tmp/b.h").str)", "c.h -> \(Path.root.join("tmp/c.h").str)"])

        // Test over-write.
        hmap.insert(Path("b.h"), value: Path.root.join("tmp/b.h"))
        #expect(hmap.debugBindings == ["a.h -> \(Path.root.join("tmp/a.h").str)", "b.h -> \(Path.root.join("tmp/b.h").str)", "c.h -> \(Path.root.join("tmp/c.h").str)"])

        // Test that table is case-insensitive on the keys.
        hmap.insert(Path("B.H"), value: Path.root.join("tmp/B.H"))
        #expect(hmap.debugBindings == ["a.h -> \(Path.root.join("tmp/a.h").str)", "B.H -> \(Path.root.join("tmp/B.H").str)", "c.h -> \(Path.root.join("tmp/c.h").str)"])
        hmap.insert(Path("D.H"), value: Path.root.join("tmp/D.H"))
        #expect(hmap.debugBindings == ["a.h -> \(Path.root.join("tmp/a.h").str)", "B.H -> \(Path.root.join("tmp/B.H").str)", "c.h -> \(Path.root.join("tmp/c.h").str)", "D.H -> \(Path.root.join("tmp/D.H").str)"])
        hmap.insert(Path("d.h"), value: Path.root.join("tmp/d.h"))
        #expect(hmap.debugBindings == ["a.h -> \(Path.root.join("tmp/a.h").str)", "B.H -> \(Path.root.join("tmp/B.H").str)", "c.h -> \(Path.root.join("tmp/c.h").str)", "d.h -> \(Path.root.join("tmp/d.h").str)"])
    }
}
