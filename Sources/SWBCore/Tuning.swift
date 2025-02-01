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

/// A namespace for "tuning" parameters (magic constants).
public struct Tuning {
    /// The TTL for the in-memory incremental PIF object cache.
    public static let pifCacheTTL = Duration.seconds(60)

    /// The TTL for each WorkspaceContext's Settings cache.
    public static let workspaceSettingsCacheTTL = Duration.seconds(60)
}
