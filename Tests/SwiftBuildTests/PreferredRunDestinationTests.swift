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

import Testing
import SwiftBuild
import SwiftBuildTestSupport
import SWBTestSupport
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct PreferredRunDestinationTests {
    @Test(.requireSDKs(.macOS))
    func platformExists() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }
                let runDestination = try await testSession.session.preferredRunDestination(forPlatform: "macosx")
                #expect(runDestination.sdk == "macosx")
            }
        }
    }

    @Test
    func unknownPlatform() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }
                await #expect(throws: (any Error).self) {
                    try await testSession.session.preferredRunDestination(forPlatform: "unknown_platform")
                }
            }
        }
    }
}
