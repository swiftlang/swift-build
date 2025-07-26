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

    /// Creates a pipe, marking both ends close-on-exec where the platform
    /// supports doing so.
    ///
    /// On Apple platforms this uses the atomic `pipe2` syscall when built against
    /// an SDK which declares it and running on an OS which provides it, and
    /// otherwise falls back to `pipe` followed by a (non-atomic)
    /// `fcntl(F_SETFD, FD_CLOEXEC)`. Elsewhere (including Windows) it uses
    /// swift-system's `pipe2`-based API.
    public static func safePipe() throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
        #if canImport(Darwin)
        var fds: (Int32, Int32) = (-1, -1)
        let result = withUnsafeMutablePointer(to: &fds) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 2) { fds in
                swb_pipe_cloexec(fds)
            }
        }
        guard result == 0 else {
            throw Errno(rawValue: errno)
        }
        return (readEnd: FileDescriptor(rawValue: fds.0), writeEnd: FileDescriptor(rawValue: fds.1))
        #else
        return try pipe(options: .closeOnExec)
        #endif
    }

    /// Duplicates this file descriptor onto `target`, marking the new descriptor
    /// close-on-exec where the platform supports doing so.
    ///
    /// On Apple platforms this uses the atomic `dup3` syscall when built against
    /// an SDK which declares it and running on an OS which provides it, and
    /// otherwise falls back to `dup2` followed by a (non-atomic)
    /// `fcntl(F_SETFD, FD_CLOEXEC)`. Other non-Windows platforms use
    /// swift-system's `dup3`-based API. Windows has no `dup3`, so it falls back
    /// to a plain `dup2`, which does not set close-on-exec.
    public func safeDuplicate(as target: FileDescriptor, retryOnInterrupt: Bool = true) throws -> FileDescriptor {
        #if canImport(Darwin)
        while true {
            let newValue = swb_dup3_cloexec(self.rawValue, target.rawValue)
            if newValue >= 0 {
                return FileDescriptor(rawValue: newValue)
            }
            let error = Errno(rawValue: errno)
            guard retryOnInterrupt && error == .interrupted else { throw error }
        }
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
