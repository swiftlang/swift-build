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

import SWBCore
import SWBTaskConstruction
import SWBUtil
import Testing

@Suite
fileprivate struct XCFrameworkContextTests {
    @Test
    func outputPathCacheReusesEnumeratedOutputsForMatchingCopyConfigurations() throws {
        let library = XCFramework.Library(
            libraryIdentifier: "macos-arm64",
            supportedPlatform: "macos",
            supportedArchitectures: ["arm64"],
            platformVariant: nil,
            libraryPath: Path("Support.framework"),
            binaryPath: Path("Support.framework/Support"),
            headersPath: nil
        )
        let xcframework = try XCFramework(version: Version(1, 0), libraries: [library])
        let fs = PseudoFS()
        let xcframeworkPath = Path("/tmp/Support.xcframework")
        let selectedLibraryPath = xcframeworkPath.join(library.libraryIdentifier).join(library.libraryPath)
        try fs.createDirectory(selectedLibraryPath, recursive: true)
        try fs.write(selectedLibraryPath.join("Info.plist"), contents: "")
        try fs.write(selectedLibraryPath.join("Support"), contents: "")

        var cache = XCFrameworkOutputPathCache()
        let outputDirectory = Path("/tmp/build")
        let first = try cache.outputPaths(for: xcframework, library: library, from: xcframeworkPath, to: outputDirectory, fs: fs)

        try fs.write(selectedLibraryPath.join("AddedAfterFirstEnumeration"), contents: "")

        let second = try cache.outputPaths(for: xcframework, library: library, from: xcframeworkPath, to: outputDirectory, fs: fs)
        let otherOutputDirectory = try cache.outputPaths(for: xcframework, library: library, from: xcframeworkPath, to: Path("/tmp/other-build"), fs: fs)

        #expect(first == second)
        #expect(!second.contains(Path("/tmp/build/Support.framework/AddedAfterFirstEnumeration")))
        #expect(otherOutputDirectory.contains(Path("/tmp/other-build/Support.framework/AddedAfterFirstEnumeration")))
    }
}
