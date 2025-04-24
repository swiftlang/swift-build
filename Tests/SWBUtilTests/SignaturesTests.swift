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
import SWBTestSupport

@Suite(.requireHostOS(.macOS), .requireSDKs(.macOS))
fileprivate struct SignaturesTests {
    let fs = localFS

    @Test
    func basics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let rootPath: Path = tmpDir.path
            let bundlePath = rootPath.join("test.bundle")
            try fs.createDirectory(bundlePath, recursive: true)
            try await fs.writePlist(bundlePath.join("Info.plist"), .plDict([:]))
            try fs.write(bundlePath.join("test"), contents: "#!/bin/bash", atomically: true)

            let codesignTool = URL(fileURLWithPath: "/usr/bin/codesign")

            // Set-up the ad-hoc signed bundle for testing.
            let codesignSigningResult = try await Process.run(url: codesignTool, arguments: ["-s", "-", "-i", "test-ident", bundlePath.str])
            #expect(codesignSigningResult.isSuccess)

            let info = try await CodeSignatureInfo.load(from: bundlePath.str, additionalInfo: nil)
            #expect(info.identifier == "test-ident")
        }
    }

    @Test
    func errorWithModifiedContent() async throws {
        try await withTemporaryDirectory { tmpDir in
            let rootPath: Path = tmpDir.path
            let bundlePath = rootPath.join("test.bundle")
            try fs.createDirectory(bundlePath, recursive: true)
            try await fs.writePlist(bundlePath.join("Info.plist"), .plDict([:]))
            try fs.write(bundlePath.join("test"), contents: "#!/bin/bash", atomically: true)

            let codesignTool = URL(fileURLWithPath: "/usr/bin/codesign")

            // Set-up the ad-hoc signed bundle for testing.
            let codesignSigningResult = try await Process.run(url: codesignTool, arguments: ["-s", "-", bundlePath.str])
            #expect(codesignSigningResult.isSuccess)

            // Modify the contents of the test bundle to ensure that `codesign -v` will fail.
            try fs.copy(Path("\(bundlePath.str)/Info.plist"), to: Path("\(bundlePath.str)/Info-Copy.plist"))

            do {
                _ = try await CodeSignatureInfo.load(from: bundlePath, additionalInfo: nil)
                Issue.record("Expected an error to be thrown, but it was not.")
            } catch let CodeSignatureInfo.Error.codesignVerificationFailed(description, output) {
                #expect(description == "A sealed resource is missing or invalid")
                #expect(try output.split(separator: "\n").filter { line in
                    try #/--(prepared|validated):/.+/Contents/Frameworks/libclang_rt\.(asan|tsan|ubsan)_osx_dynamic\.dylib/#.wholeMatch(in: line) == nil
                } == [
                    "\(bundlePath.str): a sealed resource is missing or invalid",
                    "file added: \(bundlePath.str)/Info-Copy.plist"
                ])
            } catch {
                Issue.record(error)
            }
        }
    }

    @Test
    func noErrorWithModifiedContentNoSignature() async throws {
        try await withTemporaryDirectory { (tmpDir: NamedTemporaryDirectory) in
            let rootPath: Path = tmpDir.path
            let bundlePath = rootPath.join("test.bundle")
            try fs.createDirectory(bundlePath, recursive: true)
            try await fs.writePlist(bundlePath.join("Info.plist"), .plDict([:]))
            try fs.write(bundlePath.join("test"), contents: "#!/bin/bash", atomically: true)

            // Modify the contents of the test bundle to ensure that `codesign -v` will fail.
            try fs.copy(Path("\(bundlePath.str)/Info.plist"), to: Path("\(bundlePath.str)/Info-Copy.plist"))

            await #expect(throws: Never.self) {
                try await CodeSignatureInfo.load(from: bundlePath, additionalInfo: nil)
            }
        }
    }
}
