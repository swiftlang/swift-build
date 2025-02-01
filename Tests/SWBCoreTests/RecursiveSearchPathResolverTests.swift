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
import SWBCore
import SWBTestSupport
import SWBUtil

@Suite fileprivate struct RecursiveSearchPathResolverTests {
    /// Check the basic behaviors on a real filesystem.
    @Test(.skipHostOS(.windows, "POSIX permissions model is inapplicable to Windows"), .disabled(if: ProcessInfo.processInfo.effectiveUserID == 0, "chmod 100 won't prevent directory traversal when running as root"))
    func basics() async throws {
        let fs = localFS
        let resolver = RecursiveSearchPathResolver(fs: localFS)

        try await withTemporaryDirectory { tmpDirPath in
            try fs.createDirectory(tmpDirPath.join("subdir/subsubdir"), recursive: true)
            try fs.createDirectory(tmpDirPath.join("other"))
            try fs.write(tmpDirPath.join("not-a-dir"), contents: "")

            // Create an inaccessible subpath.
            try fs.createDirectory(tmpDirPath.join("inaccessible/subdir"), recursive: true)
            try await runProcess(["/bin/chmod", "100", tmpDirPath.join("inaccessible").str])

            let (paths, warnings) = resolver.expandedPaths(for: tmpDirPath, relativeTo: tmpDirPath)
            #expect(paths.map{ $0.str } == [
                ".",
                // This directory can be seen, but not traversed.
                "inaccessible",
                "other",
                "subdir",
                "subdir/subsubdir"])
            XCTAssertMatch(warnings, [
                .regex(#/unable to expand children of '.*/inaccessible'/#),
            ])

            // Allow the inaccessible path to be removed.
            try await runProcess(["/bin/chmod", "755", tmpDirPath.join("inaccessible").str])
        }
    }

    /// Check the resolver handles relative to slash correctly.
    @Test(.skipHostOS(.windows, "path operators need some work"))
    func relativeToRoot() throws {
        let fs = PseudoFS()
        let resolver = RecursiveSearchPathResolver(fs: fs)
        try fs.createDirectory(Path.root.join("a/b"), recursive: true)
        let (paths, _) = resolver.expandedPaths(for: Path.root.join("a"), relativeTo: .root)
        #expect(paths.map{ $0.str } == ["a", "a/b"])
    }

    /// Check the resolver honors the entry limit.
    @Test
    func entryLimit() throws {
        let fs = PseudoFS()
        let resolver = RecursiveSearchPathResolver(fs: fs)
        let N = 10000
        for i in 0 ..< N {
            try fs.createDirectory(Path.root.join("dir-\(i)"), recursive: false)
        }
        let (paths, _) = resolver.expandedPaths(for: .root, relativeTo: .root)
        #expect(paths.count == RecursiveSearchPathResolver.maximumNumberOfEntries)
    }

    /// Check the included and excluded patterns.
    @Test(.skipHostOS(.windows, "Path handling needs work for windows"))
    func includedAndExcluded() throws {
        func check(files: [Path], excluded: [String]? = nil, included: [String]? = nil, expected: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
            let fs = PseudoFS()
            let resolver = RecursiveSearchPathResolver(fs: fs)
            for path in files {
                try fs.createDirectory(path, recursive: true)
            }

            let (paths, warnings) = resolver.expandedPaths(for: .root, relativeTo: .root, excludedPatterns: excluded, includedPatterns: included)
            #expect(warnings == [])
            #expect(paths.map{ $0.str } == expected)
        }

        try check(files: [.root.join("a"), .root.join("aa"), .root.join("b"), .root.join("c")], excluded: ["a*"], included: ["aa"], expected: [".", "aa", "b", "c"])
        try check(files: [.root.join("a"), .root.join("b")], included: ["a"], expected: [".", "a", "b"])
        try check(files: [.root.join("a"), .root.join("b")], excluded: ["*"], expected: ["."])
        try check(files: [.root.join("aa"), .root.join("ba")], excluded: ["*"], included: ["*a*"], expected: [".", "aa", "ba"])
    }
}
