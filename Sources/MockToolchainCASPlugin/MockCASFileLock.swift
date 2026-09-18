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

import SWBLibc
import SWBUtil

#if os(Windows)
import WinSDK
#endif

/// An advisory lock over a sibling `<path>.lock` file, used to serialize read-modify-write access
/// to the JSON store files that multiple independent `MockCAS` instances (potentially from
/// different processes) may share.
final class MockCASFileLock {
    private let lockPath: Path

    init(protecting path: Path) {
        self.lockPath = Path(path.str + ".lock")
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try localFS.createDirectory(lockPath.dirname, recursive: true)
        #if os(Windows)
        let handle: HANDLE = lockPath.str.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, UInt32(GENERIC_READ) | UInt32(GENERIC_WRITE), UInt32(FILE_SHARE_READ) | UInt32(FILE_SHARE_WRITE), nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard handle != INVALID_HANDLE_VALUE else {
            throw StubError.error("could not open lock file at \(lockPath.str): \(GetLastError())")
        }
        defer { CloseHandle(handle) }
        var overlapped = OVERLAPPED()
        overlapped.Offset = 0
        overlapped.OffsetHigh = 0
        overlapped.hEvent = nil
        guard LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, UInt32.max, UInt32.max, &overlapped) else {
            throw StubError.error("could not lock file at \(lockPath.str): \(GetLastError())")
        }
        defer {
            var unlockOverlapped = OVERLAPPED()
            unlockOverlapped.Offset = 0
            unlockOverlapped.OffsetHigh = 0
            unlockOverlapped.hEvent = nil
            UnlockFileEx(handle, 0, UInt32.max, UInt32.max, &unlockOverlapped)
        }
        return try body()
        #else
        let fd = open(lockPath.str, O_WRONLY | O_CREAT, 0o666)
        guard fd >= 0 else {
            throw StubError.error("could not open lock file at \(lockPath.str): errno \(errno)")
        }
        defer { close(fd) }
        while true {
            if flock(fd, LOCK_EX) == 0 {
                break
            }
            if errno == EINTR { continue }
            throw StubError.error("could not lock file at \(lockPath.str): errno \(errno)")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
        #endif
    }
}
