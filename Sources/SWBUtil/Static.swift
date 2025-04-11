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

import SWBLibc
import Synchronization

// This is a workaround for Swift's lack of local-static (rdar://problem/17662275) or in
// generics (rdar://problem/22882266).

/// The lock used to ensure thread safety.
private let staticStorageLock = SWBMutex(())

public struct StaticStorageKey: Hashable, Sendable {
    let file: StaticString
    let line: Int
    let column: Int

    public func hash(into hasher: inout Hasher) {
        hasher.combine(file.utf8Start)
        hasher.combine(line)
        hasher.combine(column)
    }

    public static func ==(lhs: StaticStorageKey, rhs: StaticStorageKey) -> Bool {
        return lhs.file.utf8Start == rhs.file.utf8Start && lhs.line == rhs.line && lhs.column == rhs.column
    }
}

public protocol StaticStorable {
    /// The static storage table for the type. This is `nonisolated(unsafe)` because it's protected by `staticStorageLock` and should never be accessed outside the `Static` function.
    nonisolated(unsafe) static var staticStorageTable: [StaticStorageKey: Self] { get set }
}

/// Define a static property (whose value is only computed once per execution).
///
/// This function *must not* be used within generics without also inheriting the file, line, and column from the enclosing scope.
//
// This works by inheriting the location of the caller to use as our key into the static storage table. This is expensive, but at least it allows clients to preserve the same structure that they would have when Swift supports real static properties.
public func Static<T: StaticStorable & Sendable>(_ file: StaticString = #filePath, _ line: Int = #line, _ column: Int = #column, _ construct: @Sendable () -> T) -> T {
    return staticStorageLock.withLock {
        let key = StaticStorageKey(file: file, line: line, column: column)
        if let value = T.staticStorageTable[key] {
            return value
        }

        let value = construct()
        T.staticStorageTable[key] = value
        return value
    }
}
