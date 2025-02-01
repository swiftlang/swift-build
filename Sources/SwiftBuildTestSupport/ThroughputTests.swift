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

package import SwiftBuild
package import Foundation
import SWBUtil

extension SWBBuildService {
    /// Send a throughput test by sending the given data.
    package func sendThroughputTest<D: DataProtocol>(_ bytes: D) async throws -> Bool {
        // Allocate a buffer.
        var message = Array("TPUT".utf8).withUnsafeBytes { SWBDispatchData(bytes: $0) }
        assert(message.count == 4)
        Array(bytes).withUnsafeBytes { message.append($0) }
        try await setConfig(key: "TPUT", value: "TEST")
        return true
    }
}
