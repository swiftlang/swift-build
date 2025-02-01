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

@Suite fileprivate struct ArchitectureTests {
    @Test func hostArchitecture() async throws {
        #if canImport(Darwin)
        #if arch(arm64)
        #expect(Architecture.host.stringValue == "arm64")
        #expect(Architecture.host.as32bit.stringValue == "arm")
        #expect(Architecture.host.as64bit.stringValue == "arm64")
        #endif

        #if arch(x86_64)
        #expect(Architecture.host.stringValue == "x86_64")
        #expect(Architecture.host.as32bit.stringValue == "i386")
        #expect(Architecture.host.as64bit.stringValue == "x86_64")
        #endif
        #else
        #expect(Architecture.host.stringValue == nil)

        #if arch(arm64)
        #expect(Architecture.hostStringValue == "aarch64")
        #endif

        #if arch(x86_64)
        #expect(Architecture.hostStringValue == "x86_64")
        #endif
        #endif
    }
}
