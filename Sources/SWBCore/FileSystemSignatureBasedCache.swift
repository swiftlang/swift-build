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

import SWBUtil

/// Provides a cache of objects keyed by a tuple of a path, and signature representing a hash of the contents at that path.
final class FileSystemSignatureBasedCache<Value: Sendable>: Sendable {
    private struct Key: Hashable, Sendable {
        let path: Path
        let filesSignature: FilesSignature
    }

    private let cache = Cache<Key, Lazy<Result<Value, any Error>>>()
    private let block: @Sendable (Path) throws -> Value

    /// Initializes a cache.
    /// - parameter block: A block which computes the object keyed by the given path. It is the caller's responsibility to access the actual filesystem.
    init(_ block: @escaping @Sendable (Path) throws -> Value) {
        self.block = block
    }

    /// Gets the object with the given path and signature, creating it if necessary.
    public func get(at path: Path, filesSignature: FilesSignature) throws -> Value {
        return try cache.getOrInsert(Key(path: path, filesSignature: filesSignature), body: { () -> Result<Value, any Error> in
            return Result<Value, any Error> {
                try block(path)
            }
        }).get()
    }
}

protocol FileSystemInitializable {
    init(path: Path, fs: any FSProxy) throws
}

extension FileSystemSignatureBasedCache where Value: FileSystemInitializable {
    convenience init(fs: any FSProxy) {
        self.init { path in
            try Value(path: path, fs: fs)
        }
    }
}
