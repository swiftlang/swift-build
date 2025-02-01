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

@Suite fileprivate struct TBDFileTests {
    @Test
    func successfulParsing() throws {
        try withTemporaryDirectory { tmpDir throws in
            let path = tmpDir.join("file.tbd")

            #expect(try TBDFile(self.writeExampleTBD(path: path, platformString: "unknown")).platforms == [.unknown])

            #expect(try TBDFile(self.writeExampleTBD(path: path, platformString: "macosx")).platforms == [.macOS])
            #expect(try TBDFile(self.writeExampleTBD(path: path, platformString: "ios")).platforms == [.iOS])
            #expect(try TBDFile(self.writeExampleTBD(path: path, platformString: "tvos")).platforms == [.tvOS])
            #expect(try TBDFile(self.writeExampleTBD(path: path, platformString: "watchos")).platforms == [.watchOS])

            #expect(try TBDFile(writeExampleTBD(path: path, platformString: "maccatalyst")).platforms == [.macCatalyst])

            #expect(try TBDFile(self.writeExampleTBD(path: path, platformString: "driverkit")).platforms == [.driverKit])

            #expect(try TBDFile(self.writeExampleTBD(path: path, platformString: "zippered")).platforms == [.macOS, .macCatalyst])

            #expect(try TBDFile(self.writeExampleTBDV4(path: path, triples: ["arm64-macos", "arm64-maccatalyst", "arm64-ios", "arm64-ios-simulator", "arm64-tvos", "arm64-tvos-simulator", "arm64-watchos", "arm64-watchos-simulator", "arm64-driverkit", "arm64-unknown"])).platforms == [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .driverKit, .unknown])

            #expect(try TBDFile(self.writeExampleTBDV4(path: path, triples: ["x86_64-maccatalyst"])).platforms == [.macCatalyst])
        }
    }

    @Test
    func invalidPlatformValue() throws {
        try withTemporaryDirectory { (tmpDir: Path) in
            let path = tmpDir.join("file.tbd")

            #expect {
                try TBDFile(self.writeExampleTBD(path: path, platformString: "invalid"))
            } throws: { error in
                error.localizedDescription == "Could not parse TBD platform string 'invalid'"
            }

            #expect {
                try TBDFile(self.writeExampleTBDV4(path: path, triples: ["arm64-invalid"]))
            } throws: { error in
                error.localizedDescription == "Could not parse TBD platform string 'invalid'"
            }
        }
    }

    @Test
    func invalidFiles() throws {
        try withTemporaryDirectory { (tmpDir: Path) in
            let path = tmpDir.join("file.tbd")

            // Empty file
            try localFS.write(path, contents: ByteString(encodingAsUTF8: ""))
            #expect {
                try TBDFile(path)
            } throws: { error in
                error.localizedDescription == "Could not parse TBD file"
            }

            // No platform
            try localFS.write(path, contents: ByteString(encodingAsUTF8:
            """
            --- !tapi-tbd-v3
            archs:           [ x86_64 ]
            uuids:           [ 'x86_64: 1D44D9BF-DFE9-3D2C-800F-28B3AB5924E7' ]
            install-name:    '/System/iOSSupport/System/Library/Frameworks/UIKit.framework/Versions/A/UIKit'
            """))
            #expect {
                try TBDFile(path)
            } throws: { error in
                error.localizedDescription == "Could not determine platform of version 3 TBD file"
            }

            // Malformed platform
            #expect {
                try TBDFile(self.writeExampleTBD(path: path, platformString: ""))
            } throws: { error in
                error.localizedDescription == "Could not determine platform of version 3 TBD file"
            }

            #expect {
                try TBDFile(self.writeExampleTBDV4(path: path, triples: []))
            } throws: { error in
                error.localizedDescription == "Could not determine platform of version 4 TBD file"
            }

            // Multiple platforms (first malformed)
            try localFS.write(path, contents: ByteString(encodingAsUTF8:
            """
            --- !tapi-tbd-v3
            archs:           [ x86_64 ]
            uuids:           [ 'x86_64: 1D44D9BF-DFE9-3D2C-800F-28B3AB5924E7' ]
            platform:
            platform:        ios
            install-name:    '/System/iOSSupport/System/Library/Frameworks/UIKit.framework/Versions/A/UIKit'
            """))
            #expect {
                try TBDFile(path)
            } throws: { error in
                error.localizedDescription == "Could not determine platform of version 3 TBD file"
            }

            // Multiple platforms (first invalid)
            try localFS.write(path, contents: ByteString(encodingAsUTF8:
            """
            --- !tapi-tbd-v3
            archs:           [ x86_64 ]
            uuids:           [ 'x86_64: 1D44D9BF-DFE9-3D2C-800F-28B3AB5924E7' ]
            platform:        invalid
            platform:        ios
            install-name:    '/System/iOSSupport/System/Library/Frameworks/UIKit.framework/Versions/A/UIKit'
            """))
            #expect {
                try TBDFile(path)
            } throws: { error in
                error.localizedDescription == "Could not parse TBD platform string 'invalid'"
            }
        }
    }

    private func writeExampleTBD(path: Path, platformString: String) throws -> Path {
        try localFS.write(path, contents: ByteString(encodingAsUTF8:
            """
            --- !tapi-tbd-v3
            archs:           [ x86_64 ]
            uuids:           [ 'x86_64: 1D44D9BF-DFE9-3D2C-800F-28B3AB5924E7' ]
            platform:        \(platformString)
            install-name:    '/System/iOSSupport/System/Library/Frameworks/UIKit.framework/Versions/A/UIKit'
            """))
        return path
    }

    private func writeExampleTBDV4(path: Path, triples: [String]) throws -> Path {
        try localFS.write(path, contents: ByteString(encodingAsUTF8:
            """
            --- !tapi-tbd
            tbd-version:     4
            targets:         [ \(triples.joined(separator: ", ")) ]
            install-name:    '/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit'
            """))
        return path
    }
}
