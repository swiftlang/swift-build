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
import SWBCore
import SWBUtil
import Testing
import SWBTestSupport

@Suite fileprivate struct ModuleVerifierFilenameMapTests {
    @Test
    func filenameMap() async throws {
        let fs = PseudoFS()
        try await withTemporaryDirectory(fs: fs) { tmpDir in
            let path = tmpDir.join("sampleFilenameMap.json")
            try await fs.writeJSON(path, [
                "case-sensitive":"false",
                "contents": [
                    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX11.0.sdk/usr/include/err.h":"/tmp/DerivedData/test/Build/Products/Debug/test.framework/Headers/err.h"
                ],
                "version":"0"
            ])

            let filenameMap = ModuleVerifierFilenameMap(from: path, fs: fs)
            let filename = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX11.0.sdk/usr/include/err.h"
            let expectedFilename = "/tmp/DerivedData/test/Build/Products/Debug/test.framework/Headers/err.h"

            let result = filenameMap.map(filename: filename)

            #expect(result == expectedFilename)
        }
    }
}
