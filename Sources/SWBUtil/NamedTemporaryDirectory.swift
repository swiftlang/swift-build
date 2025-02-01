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
import Foundation

/// This type encapsulates an individual named temporary directory which can optionally be removed when no longer used.
public final class NamedTemporaryDirectory: Sendable {
    /// The path of the directory to use to add any contents to.
    public let path: Path

    /// The filesystem proxy used to perform filesystem operations.
    private let fs: any FSProxy

    /// The path of the created 'root' directory, which is the one that should be deleted.
    private let rootPath: Path

    /// Whether the directory should be deleted when the struct goes out of scope.
    private let delete: LockedValue<Bool>

    /// Create a new named temporary directory.
    /// - remark: This is not a safe API to use if you cannot guarantee the lifetime of of the instance you are tracking. If possible, it is better to use the `withTemporaryDirectory()` function to ensure proper lifetime handling.
    public init(parent: Path? = nil, fs: any FSProxy = localFS, delete: Bool = true, excludeFromBackup: Bool = true) throws {
        self.fs = fs
        self.rootPath = try fs.createTemporaryDirectory(parent: parent ?? fs.realpath(Path.temporaryDirectory))

        // Exclude from backups
        if excludeFromBackup {
            try fs.setIsExcludedFromBackup(rootPath, true)
        }

        // Always make the path have a '.noindex' subpath, to exclude it from MDS.
        self.path = rootPath.join("Data.noindex")
        try fs.createDirectory(self.path, recursive: true)
        self.delete = .init(delete)
    }

    /// Marks the directory as no longer being cleaned up automatically.
    public func disown() {
        delete.withLock { $0 = false }
    }

    @_spi(TestSupport) public func remove() throws {
        let pathToDelete = rootPath

        // If SAVE_TEMPS is enabled, don't automatically delete the directory.
        if getEnvironmentVariable("SAVE_TEMPS")?.nilIfEmpty != nil {
            log("automatically preserving temporary directory due to SAVE_TEMPS: \(pathToDelete)")
            return
        }

        // Delete the directory.
        // FIXME: Make this throwing again
        try? fs.removeDirectory(pathToDelete)
    }

    deinit {
        // If directed, delete the root directory when the object is deinit'ed.
        if delete.withLock({ $0 }) {
            try? remove()
        }
    }
}

/// Provides a proper RTTI encapsulation for the `NamedTemporaryDirectory` to ensure that clean and deletion happen at a deterministic time.
/// - remark: Please keep this API in sync with https://github.com/apple/swift-tools-support-core/blob/main/Sources/TSCBasic/TemporaryFile.swift until we can adopt that API
/// - remark: The `prefix` param is currently ignored.
public func withTemporaryDirectory<Result>(dir: Path? = nil, prefix: String = "", fs: any FSProxy = localFS, removeTreeOnDeinit: Bool = true, _ body: (Path) throws -> Result) throws -> Result {
    try withTemporaryDirectory(dir: dir, prefix: prefix, fs: fs, removeTreeOnDeinit: removeTreeOnDeinit) {
        try body($0.path)
    }
}

/// Provides a proper RTTI encapsulation for the `NamedTemporaryDirectory` to ensure that clean and deletion happen at a deterministic time.
/// - remark: Please keep this API in sync with https://github.com/apple/swift-tools-support-core/blob/main/Sources/TSCBasic/TemporaryFile.swift until we can adopt that API
/// - remark: The `prefix` param is currently ignored.
@_disfavoredOverload public func withTemporaryDirectory<Result>(dir: Path? = nil, prefix: String = "", fs: any FSProxy = localFS, removeTreeOnDeinit: Bool = true, _ body: (NamedTemporaryDirectory) throws -> Result) throws -> Result {
    return try withExtendedLifetime(NamedTemporaryDirectory(parent: dir, fs: fs, delete: removeTreeOnDeinit, excludeFromBackup: true)) { tmpDir in
        let result = try body(tmpDir)
        if removeTreeOnDeinit {
            tmpDir.disown()
            try tmpDir.remove()
        }
        return result
    }
}

// Workaround for: rdar://71098795 (Investigate reasync design)
public func withTemporaryDirectory<Result>(dir: Path? = nil, prefix: String = "", fs: any FSProxy = localFS, removeTreeOnDeinit: Bool = true, _ body: (Path) async throws -> Result) async throws -> Result {
    try await withTemporaryDirectory(dir: dir, prefix: prefix, fs: fs, removeTreeOnDeinit: removeTreeOnDeinit) {
        try await body($0.path)
    }
}

// Workaround for: rdar://71098795 (Investigate reasync design)
@_disfavoredOverload public func withTemporaryDirectory<Result>(dir: Path? = nil, prefix: String = "", fs: any FSProxy = localFS, removeTreeOnDeinit: Bool = true, _ body: (NamedTemporaryDirectory) async throws -> Result) async throws -> Result {
    try await withExtendedLifetime(NamedTemporaryDirectory(parent: dir, fs: fs, delete: removeTreeOnDeinit, excludeFromBackup: true)) { tmpDir in
        let result = try await body(tmpDir)
        if removeTreeOnDeinit {
            tmpDir.disown()
            try tmpDir.remove()
        }
        return result
    }
}

// Workaround for: rdar://81725360 (A version of withExtendedLifetime and takes an async closure)
fileprivate func withExtendedLifetime<T, Result>(_ x: T, _ body: (T) async throws -> Result) async rethrows -> Result {
    defer { _fixLifetime(x) }
    return try await body(x)
}
