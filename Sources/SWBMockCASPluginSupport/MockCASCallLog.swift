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

import Foundation
public import SWBUtil

/// Reads and parses the call log written by `MockToolchainCASPlugin` at `<casPath>/call_log.jsonl`.
///
/// Returns an empty array if the log doesn't exist yet (e.g. no calls have been made against that
/// CAS path).
public func readCallLog(at casPath: Path, fs: any FSProxy = localFS) throws -> [MockCASCallLogEntry] {
    let logPath = casPath.join("call_log.jsonl")
    guard fs.exists(logPath) else {
        return []
    }
    let contents = try fs.read(logPath)
    let decoder = JSONDecoder()
    return try contents.asString.split(separator: "\n").filter { !$0.isEmpty }.map { line in
        try decoder.decode(MockCASCallLogEntry.self, from: Data(line.utf8))
    }
}
