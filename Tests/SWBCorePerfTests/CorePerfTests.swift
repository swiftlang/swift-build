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
import SWBUtil
import SWBCore
import SWBTestSupport

@Suite(.performance)
fileprivate struct CorePerfTests: PerfTests {
    @Test
    func specRegistrationPerf() async throws {
        try await measure {
            try await Core.perfTestSpecRegistration()
        }
    }

    @Test
    func completeSpecLoadingPerf() async throws {
        try await measure {
            try await Core.perfTestSpecLoading()
        }
    }
}
