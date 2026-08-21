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

private import SWBLibc

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

extension FileDescriptor {
    /// Opens or creates a file for reading or writing, always marking the
    /// descriptor close-on-exec so that it is not leaked into child processes.
    ///
    /// This is a thin wrapper over `FileDescriptor.open(_:_:options:permissions:retryOnInterrupt:)`
    /// which forces `.closeOnExec`.
    public static func safeOpen(_ path: FilePath, _ mode: FileDescriptor.AccessMode, options: FileDescriptor.OpenOptions = FileDescriptor.OpenOptions(), permissions: FilePermissions? = nil, retryOnInterrupt: Bool = true) throws -> FileDescriptor {
        var options = options
        options.insert(.closeOnExec)
        return try open(path, mode, options: options, permissions: permissions, retryOnInterrupt: retryOnInterrupt)
    }

    /// Creates a pipe, atomically marking both ends close-on-exec where the
    /// platform supports doing so.
    ///
    /// The atomic `pipe2`-based API is used wherever it is available: on non-Apple
    /// platforms (including Windows) via swift-system's `SystemPackage`, and on
    /// Apple platforms running an OS new enough to vend the underlying `pipe2`
    /// syscall via the SDK's `System` framework. On older Apple OSes we fall back
    /// to a plain `pipe`, which does not set close-on-exec.
    public static func safePipe() throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
        #if canImport(System)
        // TODO: Enable once we can build against the macOS 27 SDK, which vends
        // FileDescriptor.pipe(options:).
        #if false
        if #available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
            return try pipe(options: .closeOnExec)
        }
        #endif
        return try pipe()
        #else
        return try pipe(options: .closeOnExec)
        #endif
    }

    /// Duplicates this file descriptor onto `target`, atomically marking the new
    /// descriptor close-on-exec where the platform supports doing so.
    ///
    /// The atomic `dup3`-based API is used wherever it is available: on non-Apple
    /// platforms (excluding Windows) via swift-system's `SystemPackage`, and on
    /// Apple platforms running an OS new enough to vend the underlying `dup3`
    /// syscall via the SDK's `System` framework. Elsewhere — older Apple OSes and
    /// Windows, which has no `dup3` — we fall back to a plain `dup2`, which does
    /// not set close-on-exec.
    public func safeDuplicate(as target: FileDescriptor, retryOnInterrupt: Bool = true) throws -> FileDescriptor {
        #if canImport(System)
        // TODO: Enable once we can build against the macOS 27 SDK, which vends
        // FileDescriptor.duplicate(as:options:).
        #if false
        if #available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
            return try duplicate(as: target, options: .closeOnExec, retryOnInterrupt: retryOnInterrupt)
        }
        #endif
        return try duplicate(as: target, retryOnInterrupt: retryOnInterrupt)
        #elseif os(Windows)
        return try duplicate(as: target, retryOnInterrupt: retryOnInterrupt)
        #else
        return try duplicate(as: target, options: .closeOnExec, retryOnInterrupt: retryOnInterrupt)
        #endif
    }

    /// Duplicates this file descriptor onto the lowest-numbered unused descriptor,
    /// marking the new descriptor close-on-exec where the platform supports it.
    ///
    /// On non-Windows platforms this uses `fcntl(F_DUPFD_CLOEXEC)`, which obtains
    /// the new descriptor and sets close-on-exec atomically — a plain `dup()`
    /// followed by `fcntl(F_SETFD, FD_CLOEXEC)` would race against a concurrent
    /// `fork()`/`exec()`. On Windows, which has no `F_DUPFD_CLOEXEC`, we fall back
    /// to a plain `dup`, which does not set close-on-exec.
    public func safeDuplicate(retryOnInterrupt: Bool = true) throws -> FileDescriptor {
        #if os(Windows)
        return try duplicate(retryOnInterrupt: retryOnInterrupt)
        #else
        while true {
            let newValue = swb_dup_cloexec(self.rawValue)
            if newValue >= 0 {
                return FileDescriptor(rawValue: newValue)
            }
            let error = Errno(rawValue: errno)
            guard retryOnInterrupt && error == .interrupted else { throw error }
        }
        #endif
    }
}
