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
import SwiftBuild
import SwiftBuildTestSupport
import SWBTestSupport
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct ToolchainTests {
    @Test
    func lateRegistration() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }
                try localFS.createDirectory(tmpDirPath.join("Foo.xctoolchain"))
                try await localFS.writePlist(tmpDirPath.join("Foo.xctoolchain/Info.plist"), ["Identifier" : "org.swift.foo"])
                do {
                    let identifier = try await testSession.session.registerToolchain(at: tmpDirPath.join("Foo.xctoolchain").str)
                    #expect(identifier == "org.swift.foo")
                }
                // Late registration should be idempotent
                do {
                    let identifier = try await testSession.session.registerToolchain(at: tmpDirPath.join("Foo.xctoolchain").str)
                    #expect(identifier == "org.swift.foo")
                }
            }
        }
    }
}
