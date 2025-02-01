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
import SWBTestSupport
import SWBUtil
import Testing

#if canImport(AppleArchive)
@Suite fileprivate struct XCBuildDataArchiveTests {
    @Test
    func appendBuildDataSerial() async throws {
        try await withTemporaryDirectory { tmpDir in
            let archive = XCBuildDataArchive(filePath: tmpDir.join("XCBuildData.aar"))

            let uuids = try (0..<3).map { _ -> UUID in
                let uuid = UUID()
                let dir = tmpDir.join(UUID().description).join("XCBuildData")
                try localFS.createDirectory(dir, recursive: true)
                try localFS.write(dir.join("manifest.json"), contents: "manifest")
                try archive.appendBuildDataDirectory(from: dir, uuid: uuid)
                return uuid
            }

            let output = try await runProcess(["/usr/bin/yaa", "list", "-i", archive.archiveFilePath.str])
            #expect(output.split(separator: "\n").map(String.init) == uuids.flatMap { [$0.description, "\($0)/manifest.json"] })
        }
    }

    @Test
    func appendBuildDataConcurrent() async throws {
        try await withTemporaryDirectory { tmpDir in
            let archive = XCBuildDataArchive(filePath: tmpDir.join("XCBuildData.aar"))

            let uuids = try await Array(0..<3).asyncMap { _ -> UUID in
                let uuid = UUID()
                let dir = tmpDir.join(UUID().description).join("XCBuildData")
                try localFS.createDirectory(dir, recursive: true)
                try localFS.write(dir.join("manifest.json"), contents: "manifest")
                try archive.appendBuildDataDirectory(from: dir, uuid: uuid)
                return uuid
            }

            let output = try await runProcess(["/usr/bin/yaa", "list", "-i", archive.archiveFilePath.str])
            #expect(output.split(separator: "\n").map(String.init).sorted() == uuids.flatMap { [$0.description, "\($0)/manifest.json"] }.sorted())
        }
    }

    @Test
    func badInput() throws {
        #expect {
            try withTemporaryDirectory { tmpDir in
                let archive = XCBuildDataArchive(filePath: tmpDir.join("XCBuildData.aar"))
                try archive.appendBuildDataDirectory(from: Path("/tmp"), uuid: UUID())
            }
        } throws: { error in
            error as? StubError == .error("/tmp is not an XCBuildData directory")
        }
    }
}
#endif
