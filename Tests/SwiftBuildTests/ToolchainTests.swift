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

import struct Foundation.UUID

import SwiftBuild
import SwiftBuildTestSupport

import SWBCore
import SWBTestSupport
@_spi(Testing) import SWBUtil

import Testing

@Suite
fileprivate struct ToolchainTests: CoreBasedTests {
    @Test(.skipIfEnvironmentVariableSet(key: .externalToolchainsDir))
    func toolchainLookupByPath() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            let tmpDir = temporaryDirectory.path
            try await withAsyncDeferrable { deferrable in
                try localFS.createDirectory(tmpDir.join("toolchain.xctoolchain"))
                try await localFS.writePlist(tmpDir.join("toolchain.xctoolchain/Info.plist"), .plDict(["Identifier": "com.foo.bar"]))
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory, environment: ["EXTERNAL_TOOLCHAINS_DIR": tmpDir.str])
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }
                
                let id = try await testSession.session.lookupToolchain(at: tmpDir.join("toolchain.xctoolchain").str)
                #expect(id?.rawValue == "com.foo.bar")
            }
        }
    }
}
