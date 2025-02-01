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
@_spi(Testing) import SWBCore
import SWBUtil
import Testing

@Suite fileprivate struct ModuleVerifierHeaderTests {
    fileprivate func assert(header: ModuleVerifierHeader, file: Path, frameworkName: String, subFolder: [String], headerName: String, language: ModuleVerifierLanguage, include: String, cPlusPlus: Bool) {
        #expect(header.file == file)
        #expect(header.framework == frameworkName)
        #expect(header.subFolder == subFolder)
        #expect(header.header == headerName)
        #expect(header.include(language: language) == include)
    }

    @Test
    func header() throws {
        try withTemporaryDirectory { tmpDir in
            let headerPath = tmpDir.join("PerfectFramework.framework/Versions/A/Headers/PerfectFramework.h")
            try localFS.createDirectory(headerPath.dirname, recursive: true)
            try localFS.write(headerPath, contents: """
                #import <PerfectFramework/PerfectHeader.h>
                """)

            let header = ModuleVerifierHeader(header: headerPath, frameworkName: "PerfectFramework")

            self.assert(header: header,
                        file: headerPath,
                        frameworkName: "PerfectFramework",
                        subFolder: [],
                        headerName: "PerfectFramework.h",
                        language: .objectiveC,
                        include: "#import <PerfectFramework/PerfectFramework.h>",
                        cPlusPlus: false)
        }
    }
}
