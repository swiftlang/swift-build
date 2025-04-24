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

public import SWBLibc

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

public import struct Foundation.Data
public import struct Foundation.Date
public import struct Foundation.FileAttributeKey
public import class Foundation.FileHandle
public import class Foundation.FileManager
public import class Foundation.NSNumber
public import struct Foundation.URL
public import struct Foundation.URLResourceKey
public import struct Foundation.URLResourceValues
public import struct Foundation.UUID

#if os(Windows)
// Windows' POSIX layer does not have S_IFLNK, so define it.
// We only need it for PseudoFS.
fileprivate let S_IFLNK: Int32 = 0o0120000
#endif

/// File system information for a particular file.
///
/// This is a simple wrapper for stat() information.
public struct FileInfo: Equatable, Sendable {
    public let statBuf: stat

    public init(_ statBuf: stat) {
        self.statBuf = statBuf
    }

    public var isFile: Bool {
        #if os(Windows)
        return (statBuf.st_mode & UInt16(ucrt.S_IFREG)) != 0
        #else
        return (statBuf.st_mode & S_IFREG) != 0
        #endif
    }

    public var isDirectory: Bool {
        #if os(Windows)
        return (statBuf.st_mode & UInt16(ucrt.S_IFDIR)) != 0
        #else
        return (statBuf.st_mode & S_IFDIR) != 0
        #endif
    }

    public var isSymlink: Bool {
        #if os(Windows)
        return (statBuf.st_mode & UInt16(S_IFLNK)) == S_IFLNK
        #else
        return (statBuf.st_mode & S_IFMT) == S_IFLNK
        #endif
    }

    public var isExecutable: Bool {
        #if os(Windows)
        // Per https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/stat-functions, "user execute bits are set according to the filename extension".
        // Don't use FileManager.isExecutableFile due to https://github.com/swiftlang/swift-foundation/issues/860
        return (statBuf.st_mode & UInt16(_S_IEXEC)) != 0
        #else
        return (statBuf.st_mode & S_IXUSR) != 0
        #endif
    }

    public var permissions: Int {
        return Int(statBuf.st_mode & 0o777)
    }

    public var owner: Int {
        return Int(statBuf.st_uid)
    }

    public var group: Int {
        return Int(statBuf.st_gid)
    }

    public var modificationTimestamp: time_t {
        return statBuf.st_mtimespec.tv_sec
    }

    public var modificationDate: Date {
        let secs = statBuf.st_mtimespec.tv_sec
        let nsecs = statBuf.st_mtimespec.tv_nsec
        // Using reference date, instead of 1970, which offers a bit more nanosecond precision since it is a lower absolute number.
        return Date(timeIntervalSinceReferenceDate: Double(secs) - Date.timeIntervalBetween1970AndReferenceDate + (1.0e-9 * Double(nsecs)))
    }

    public static func ==(lhs: FileInfo, rhs: FileInfo) -> Bool {
        return lhs.statBuf == rhs.statBuf
    }
}

public enum FileSystemMode: Sendable {
    case fullStat
    case deviceAgnostic
    case checksumOnly

    public var manifestLabel: String {
        switch self {
        case .checksumOnly: return "checksum-only"
        case .deviceAgnostic: return "device-agnostic"
        case .fullStat: return "default"
        }
    }
}

/// Abstracted access to file system operations.
///
/// This protocol is used to allow one part of the codebase to interact with a natural filesystem interface, while still allowing clients to transparently substitute a virtual file system or redirect file system operations.
///
/// NOTE: All of these APIs are synchronous and could block.
//
// FIXME: This API needs error handling support.
//
// FIXME: Design an asynchronous story?
public protocol FSProxy: AnyObject, Sendable {
    var ignoreFileSystemDeviceInodeChanges: Bool { get }

    var fileSystemMode: FileSystemMode { get }

    /// Check whether the given path exists.
    //
    // FIXME: Need to document behavior w.r.t. error handling.
    func exists(_ path: Path) -> Bool

    /// Check whether the given path is a file.
    //
    // FIXME: Need to document behavior w.r.t. error handling.
    func isFile(_ path: Path) throws -> Bool

    /// Check whether the given path is a directory.
    //
    // FIXME: Need to document behavior w.r.t. error handling.
    func isDirectory(_ path: Path) -> Bool

    /// Checks whether the given path has the execute bit (which on Windows is determined by the file extension).
    func isExecutable(_ path: Path) throws -> Bool

    /// Checks whether the given path is a symlink, also returning whether the linked file exists.
    func isSymlink(_ path: Path, _ destinationExists: inout Bool) -> Bool

    /// Get the contents of the given directory, in an arbitrary order.
    func listdir(_ path: Path) throws -> [String]

    /// Create the given directory.
    func createDirectory(_ path: Path) throws

    /// Create the given directory.
    ///
    /// - recursive: If true, create missing parent directories if possible.
    func createDirectory(_ path: Path, recursive: Bool) throws

    func createTemporaryDirectory(parent: Path) throws -> Path

    func read<T>(_ path: Path, read: (FileHandle) throws -> T) throws -> T

    /// Throwing variant of readFileContents (renamed because of: <rdar://problem/28037459>)
    func read(_ path: Path) throws -> ByteString

    func readMemoryMapped(_ path: Path) throws -> Data

    /// Throwing variant of writeFileContents (renamed because of: <rdar://problem/28037459>)
    func write(_ path: Path, contents: ByteString, atomically: Bool) throws

    func write(_ path: Path, contents: (FileDescriptor) async throws -> Void) async throws

    /// Appends the content to the file at the given path. If the file does not exist, it is created.
    func append(_ path: Path, contents: ByteString) throws

    func remove(_ path: Path) throws

    /// Remove the directory at the given path.
    ///
    /// It is not an error if the give path does not exists.
    func removeDirectory(_ path: Path) throws

    func copy(_ path: Path, to: Path) throws

    func move(_ path: Path, to: Path) throws

    func moveInSameVolume(_ path: Path, to: Path) throws

    /// A.k.a. stat()
    func getFileInfo(_ path: Path) throws -> FileInfo

    /// Get the UNIX access permissions on a file.
    func getFilePermissions(_ path: Path) throws -> Int

    /// Set the UNIX access permissions on a file.
    func setFilePermissions(_ path: Path, permissions: Int) throws

    /// Get the ownership (user and group) of a file.
    func getFileOwnership(_ path: Path) throws -> (owner: Int, group: Int)

    /// Set the ownership (user and group) of a file.
    func setFileOwnership(_ path: Path, owner: Int, group: Int) throws

    /// A.k.a. lstat()
    func getLinkFileInfo(_ path: Path) throws -> FileInfo

    /// Traverse a directory tree. It would be nice to return AnySequence, but we'd need some way to handle incremental errors.
    @discardableResult func traverse<T>(_ path: Path, _ f: (Path) throws -> T?) throws -> [T]

    /// Create a symlink at `path` pointing to `target`
    func symlink(_ path: Path, target: Path) throws

    /// Excludes `path` from backup
    func setIsExcludedFromBackup(_ path: Path, _ value: Bool) throws

    /// List extended attribute names
    func listExtendedAttributes(_ path: Path) throws -> [String]

    /// Set extended attribute
    func setExtendedAttribute(_ path: Path, key: String, value: ByteString) throws

    /// Get extended attribute
    func getExtendedAttribute(_ path: Path, key: String) throws -> ByteString?

    /// Set file modification timestamp to the current time
    func touch(_ path: Path) throws

    /// Set file modification timestamp
    func setFileTimestamp(_ path: Path, timestamp: Int) throws

    /// Get file modification timestamp
    func getFileTimestamp(_ path: Path) throws -> Int

    /// Determines if `path` or any of its ancestor paths is excluded from backup. We currently don't provide any API to query if a child has the exclude flag without considering its ancestors (primarily because we don't need it, and because the current underlying implementation makes it inconvenient).
    func isPathOrAnyAncestorExcludedFromBackup(_ path: Path) throws -> Bool

    /// readlink(3)
    func readlink(_ path: Path) throws -> Path

    /// realpath(3)
    func realpath(_ path: Path) throws -> Path

    /// Determines if `path` might be on a remote filesystem (e.g. NFS)
    func isOnPotentiallyRemoteFileSystem(_ path: Path) -> Bool

    /// Returns the free disk space of the volume of `path` in bytes, or `nil` if the underlying FS implementation doesn't support this.
    func getFreeDiskSpace(_ path: Path) throws -> Int?
}

public extension FSProxy {
    func write(_ path: Path, contents: ByteString) throws {
        try write(path, contents: contents, atomically: false)
    }

    func createDirectory(_ path: Path) throws {
        try createDirectory(path, recursive: false)
    }

    func setExtendedAttribute(_ path: Path, key: String, value: String) throws {
        try setExtendedAttribute(path, key: key, value: ByteString(encodingAsUTF8: value))
    }

    func getExtendedAttribute(_ path: Path, key: String) throws -> String? {
        return try getExtendedAttribute(path, key: key)?.asString
    }

    func filesSignature(_ paths: [Path]) -> FilesSignature {
        return FilesSignature(paths, fs: self)
    }

    func writeIfChanged(_ path: Path, contents: ByteString) throws -> Bool {
        if try !exists(path) || read(path) != contents {
            try write(path, contents: contents)
            return true
        }
        return false
    }

    func getFreeDiskSpace(_ path: Path) throws -> Int? {
        return nil
    }

    func isSymlink(_ path: Path) -> Bool {
        var exists: Bool = false
        return isSymlink(path, &exists)
    }

    func getFileSize(_ path: Path) throws -> Int64 {
        try Int64(getFileInfo(path).statBuf.st_size)
    }
}

fileprivate extension FSProxy {
    func createFileInfo(_ statBuf: stat) -> FileInfo {
        if fileSystemMode == .deviceAgnostic {
            var buf = statBuf
            buf.st_ino = 0
            buf.st_dev = 0
            return FileInfo(buf)
        }
        return FileInfo(statBuf)
    }
}

/// Concrete FSProxy implementation which communicates with the local file system.
//
// FIXME: We may want to eventually consider forcing all code to go through an FSProxy, but for now we keep the FS interfaces around.
class LocalFS: FSProxy, @unchecked Sendable {
    var ignoreFileSystemDeviceInodeChanges: Bool {
        fileSystemMode == .deviceAgnostic
    }

    let fileManager: FileManager
    let fileSystemMode: FileSystemMode

    public convenience init(ignoreFileSystemDeviceInodeChanges: Bool = UserDefaults.ignoreFileSystemDeviceInodeChanges) {
        self.init(fileSystemMode: ignoreFileSystemDeviceInodeChanges ? .deviceAgnostic : .fullStat)
    }

    public init(fileSystemMode: FileSystemMode) {
        self.fileManager = FileManager()
        self.fileSystemMode = fileSystemMode
    }

    public func move(_ path: Path, to: Path) throws {
        try fileManager.moveItem(atPath: path.str, toPath: to.str)
    }

    public func moveInSameVolume(_ path: Path, to: Path) throws {
        #if canImport(Darwin)
        _ = try fileManager.replaceItemAt(URL(fileURLWithPath: to.str), withItemAt: URL(fileURLWithPath: path.str), options: FileManager.ItemReplacementOptions.usingNewMetadataOnly)
        #else
        // `replaceItemAt` doesn't work on swift-corelibs-foundation
        try move(path, to: to)
        #endif
    }

    /// Check whether a filesystem entity exists at the given path.
    func exists(_ path: Path) -> Bool {
        var statBuf = stat()
        if stat(path.str, &statBuf) < 0 {
            return false
        }
        return true
    }

    /// Check whether the given path is a directory.
    ///
    /// If the given path is a symlink to a directory, then this will return true if the destination of the symlink is a directory.
    func isDirectory(_ path: Path) -> Bool {
        var statBuf = stat()
        if stat(path.str, &statBuf) < 0 {
            return false
        }
        return createFileInfo(statBuf).isDirectory
    }

    /// Check whether a given path is a symlink.
    /// - parameter destinationExists: If the path is a symlink, then this `inout` parameter will be set to `true` if the destination exists.  Otherwise it will be set to `false`.
    func isSymlink(_ path: Path, _ destinationExists: inout Bool) -> Bool {
        #if os(Windows)
        do {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: path.str)
            destinationExists = exists((path.isAbsolute ? path.dirname : Path.currentDirectory).join(destination))
            return true
        } catch {
            destinationExists = false
            return false
        }
        #else
        destinationExists = false
        var statBuf = stat()
        if lstat(path.str, &statBuf) < 0 {
            return false
        }
        guard createFileInfo(statBuf).isSymlink else {
            return false
        }
        statBuf = stat()
        if stat(path.str, &statBuf) < 0 {
            return true
        }
        destinationExists = true
        return true
        #endif
    }

    func listdir(_ path: Path) throws -> [String] {
        return try fileManager.contentsOfDirectory(atPath: path.str)
    }

    /// Creates a directory at the given path.  Throws an exception if it cannot do so.
    /// - parameter recursive: If `false`, then the parent directory at `path` must already exist in order to create the directory.  If it doesn't, then it will return without creating the directory (it will not throw an exception).  If `true`, then the directory hierarchy of `path` will be created if possible.
    func createDirectory(_ path: Path, recursive: Bool) throws {
        // Try to create the directory.
        #if os(Windows)
        do {
            return try fileManager.createDirectory(atPath: path.str, withIntermediateDirectories: recursive)
        } catch {
            throw StubError.error("Could not create directory at path '\(path.str)': \(error)")
        }
        #else
        let result = mkdir(path.str, S_IRWXU | S_IRWXG | S_IRWXO)

        // If it succeeded, we are done.
        if result == 0 {
            return
        }

        // If the failure was because something exists at this path, then we examine it to see whether it means we're okay.
        if errno == EEXIST {
            var destinationExists = false
            if isDirectory(path) {
                // If the item at the path is a directory, then we're good.  This includes if it's a symlink which points to a directory.
                return
            }
            else if isSymlink(path, &destinationExists) {
                // If the item at the path is a symlink, then we check whether it's a broken symlink or points to something that is not a directory.
                if destinationExists {
                    // The destination does exist, so it's not a directory.
                    throw StubError.error("File is a symbolic link which references a path which is not a directory: \(path.str)")
                }
                else {
                    // The destination does not exist - throw an exception because we have a broken symlink.
                    throw StubError.error("File is a broken symbolic link: \(path.str)")
                }
            }
            else {
                /// The path exists but is not a directory
                throw StubError.error("File exists but is not a directory: \(path.str)")
            }
        }

        // If we are recursive and not the root path, then...
        if recursive && !path.isRoot {
            // If it failed due to ENOENT (e.g., a missing parent), then attempt to create the parent and retry.
            if errno == ENOENT {
                // Attempt to create the parent.
                guard path.isAbsolute else {
                    throw StubError.error("Cannot recursively create directory at non-absolute path: \(path.str)")
                }
                try createDirectory(path.dirname, recursive: true)

                // Re-attempt creation, non-recursively.
                try createDirectory(path)

                // We are done.
                return
            }

            // If our parent is not a directory, then report that.
            if !isDirectory(path.dirname) {
                throw StubError.error("File exists but is not a directory: \(path.dirname.str)")
            }
        }

        // Otherwise, we failed due to some other error. Report it.
        throw POSIXError(errno, context: "mkdir", path.str, "S_IRWXU | S_IRWXG | S_IRWXO")
        #endif
    }

    func createTemporaryDirectory(parent: Path) throws -> Path {
        #if os(Windows)
        return parent.join("swbuild.tmp." + UUID().description)
        #else
        // FIXME: This is an inappropriate location for general purpose infrastructure.
        let template = [UInt8](parent.join("swbuild.tmp.XXXXXXXX").str.utf8)

        // Create the temp path.
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: template.count + 1)
        template.withUnsafeBufferPointer { buf in
            memcpy(name, buf.baseAddress!, buf.count)
            name[buf.count] = 0
        }

        defer { name.deallocate() }

        // Create the temporary directory.
        guard mkdtemp(name) != nil else {
            throw POSIXError(errno, context: "mkdtemp", String(cString: name))
        }

        return Path(String(cString: name))
        #endif
    }

    func read<T>(_ path: Path, read: (FileHandle) throws -> T) throws -> T {
        do {
            let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.str))
            return try read(fh)
        } catch {
            throw StubError.error("Cannot open file handle for file at path: \(path.str): \(error.localizedDescription)")
        }
    }

    func read(_ path: Path) throws -> ByteString {
        do {
            let fd = try FileDescriptor.open(FilePath(path.str), .readOnly)
            return try fd.closeAfter {
                let data = OutputByteStream()
                let tmpBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 12, alignment: 1)
                defer { tmpBuffer.deallocate() }
                while true {
                    let n = try fd.read(into: tmpBuffer)
                    if n == 0 {
                        break
                    }
                    data <<< tmpBuffer[0..<n]
                }

                return data.bytes
            }
        } catch let error as Errno {
            throw POSIXError(error.rawValue)
        }
    }

    func readMemoryMapped(_ path: Path) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path.str), options: .alwaysMapped)
    }

    func _write(_ path: Path, contents: ByteString, mode: FileDescriptor.AccessMode, options: FileDescriptor.OpenOptions) throws {
        do {
            let fd = try FileDescriptor.open(FilePath(path.str), mode, options: options, permissions: [.ownerReadWrite, .groupRead, .otherRead])
            _ = try fd.closeAfter {
                try fd.writeAll(contents)
            }
        } catch let error as Errno {
            throw POSIXError(error.rawValue)
        }
    }

    func write(_ path: Path, contents: ByteString, atomically: Bool) throws {
        if atomically {
            try Data(contents).write(to: URL(fileURLWithPath: path.str), options: .atomic)
        } else {
            try _write(path, contents: contents, mode: .writeOnly, options: [.create, .truncate])
        }
    }

    func write(_ path: Path, contents: (FileDescriptor) async throws -> Void) async throws {
        let fd = try FileDescriptor.open(FilePath(path.str), .writeOnly, options: [.create, .truncate], permissions: [.ownerReadWrite, .groupRead, .otherRead])
        do {
            try await contents(fd)
        } catch {
            _ = try? fd.close()
            throw error
        }
        try fd.close()
    }

    func append(_ path: Path, contents: ByteString) throws {
        try _write(path, contents: contents, mode: .writeOnly, options: [.create, .append])
    }

    func copy(_ path: Path, to: Path) throws {
        try fileManager.copyItem(atPath: path.str, toPath: to.str)
    }

    func remove(_ path: Path) throws {
        guard unlink(path.str) == 0 else {
            throw POSIXError(errno, context: "unlink", path.str)
        }
    }

    func removeDirectory(_ path: Path) throws {
        if isDirectory(path) {
            #if os(Windows)
            try fileManager.removeItem(atPath: path.str)
            #else
            var paths = [path]
            try traverse(path) { paths.append($0) }
            for path in paths.reversed() {
                guard SWBLibc.remove(path.str) == 0 else {
                    throw POSIXError(errno, context: "remove", path.str)
                }
            }
            #endif
        }
    }

    func setFilePermissions(_ path: Path, permissions: Int) throws {
        #if os(Windows)
        // permissions work differently on Windows
        #else
        try eintrLoop {
            guard chmod(path.str, mode_t(permissions)) == 0 else {
                throw POSIXError(errno, context: "chmod", path.str, String(mode_t(permissions)))
            }
        }
        #endif
    }

    func setFileOwnership(_ path: Path, owner: Int, group: Int) throws {
        #if os(Windows)
        // permissions work differently on Windows
        #else
        try eintrLoop {
            guard chown(path.str, uid_t(owner), gid_t(group)) == 0 else {
                throw POSIXError(errno, context: "chown", path.str, String(uid_t(owner)), String(gid_t(group)))
            }
        }
        #endif
    }

    func touch(_ path: Path) throws {
        #if os(Windows)
        let handle: HANDLE = path.withPlatformString {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        if handle == INVALID_HANDLE_VALUE {
            throw Win32Error(GetLastError())
        }
        try handle.closeAfter {
            var ft = FILETIME()
            var st = SYSTEMTIME()
            GetSystemTime(&st)
            SystemTimeToFileTime(&st, &ft)
            if !SetFileTime(handle, nil, &ft, &ft) {
                Win32Error(GetLastError())
            }
        }
        #else
        try eintrLoop {
            guard utimensat(AT_FDCWD, path.str, nil, 0) == 0 else {
                throw POSIXError(errno, context: "utimensat", "AT_FDCWD", path.str)
            }
        }
        #endif
    }

    func setFileTimestamp(_ path: Path, timestamp: Int) throws {
        #if os(Windows)
        let handle: HANDLE = path.withPlatformString {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        if handle == INVALID_HANDLE_VALUE {
            throw Win32Error(GetLastError())
        }
        try handle.closeAfter {
            // Number of 100ns intervals between 1601 and 1970 epochs
            let delta = 116444736000000000

            let ll = UInt64((timestamp * 10000000) + delta)

            var timeInt = ULARGE_INTEGER()
            timeInt.QuadPart = ll

            var ft = FILETIME()
            ft.dwLowDateTime = timeInt.LowPart
            ft.dwHighDateTime = timeInt.HighPart
            if !SetFileTime(handle, nil, &ft, &ft) {
                throw Win32Error(GetLastError())
            }
        }
        #else
        try eintrLoop {
            #if os(Linux) || os(Android)
            let UTIME_OMIT = 1073741822
            #endif
            let atime = timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))
            let mtime = timespec(tv_sec: time_t(timestamp), tv_nsec: 0)
            guard utimensat(AT_FDCWD, path.str, [atime, mtime], 0) == 0 else {
                throw POSIXError(errno, context: "utimensat", "AT_FDCWD", path.str, String(timestamp))
            }
        }
        #endif
    }

    func getFileInfo(_ path: Path) throws -> FileInfo {
        var buf = stat()

        try eintrLoop {
            guard stat(path.str, &buf) == 0 else {
                throw POSIXError(errno, context: "stat", path.str)
            }
        }

        return createFileInfo(buf)
    }

    func getFilePermissions(_ path: Path) throws -> Int {
        return try getFileInfo(path).permissions
    }

    func getFileOwnership(_ path: Path) throws -> (owner: Int, group: Int) {
        let fileInfo = try getFileInfo(path)
        return (fileInfo.owner, fileInfo.group)
    }

    func getFileTimestamp(_ path: Path) throws -> Int {
        return try Int(getFileInfo(path).modificationTimestamp)
    }

    func isExecutable(_ path: Path) throws -> Bool {
        return try getFileInfo(path).isExecutable
    }

    func isFile(_ path: Path) throws -> Bool {
        return try getFileInfo(path).isFile
    }

    func getLinkFileInfo(_ path: Path) throws -> FileInfo {
        var buf = stat()
        #if os(Windows)
        try eintrLoop {
            guard stat(path.str, &buf) == 0 else {
                throw POSIXError(errno, context: "lstat", path.str)
            }
        }

        var destinationExists = false
        if isSymlink(path, &destinationExists) {
            buf.st_mode &= ~UInt16(ucrt.S_IFREG)
            buf.st_mode |= UInt16(S_IFLNK)
        }
        #else
        try eintrLoop {
            guard lstat(path.str, &buf) == 0 else {
                throw POSIXError(errno, context: "lstat", path.str)
            }
        }
        #endif
        return createFileInfo(buf)
    }

    @discardableResult func traverse<T>(_ path: Path, _ f: (Path) throws -> T?) throws -> [T] {
        guard let enumerator = fileManager.enumerator(atPath: path.str) else {
            throw StubError.error("Cannot traverse \(path.str)")
        }

        // FIXME: This enumerator has unclear error handling. Does nextObject() return nil on error? That's wrong.
        return try enumerator.compactMap { next in
            // FileManager.DirectoryEnumerator produces Strings that are backed
            // by NSPathStore2, which are slower to work with.
            var next = (next as? String)
            next?.makeContiguousUTF8()
            let nextPath = path.join(next)
            return try f(nextPath)
        }
    }

    func symlink(_ path: Path, target: Path) throws {
        #if os(Windows)
        try fileManager.createSymbolicLink(atPath: path.str, withDestinationPath: target.str)
        #else
        guard SWBLibc.symlink(target.str, path.str) == 0 else { throw POSIXError(errno, context: "symlink", target.str, path.str) }
        #endif
    }

    func setIsExcludedFromBackup(_ path: Path, _ value: Bool) throws {
        var url = URL(fileURLWithPath: path.str)
        var values = URLResourceValues()
        values.isExcludedFromBackup = value
        try url.setResourceValues(values)
    }

    func listExtendedAttributes(_ path: Path) throws -> [String] {
        #if os(Windows)
        // Implement ADS on Windows? See also https://github.com/swiftlang/swift-foundation/issues/1166
        return []
        #elseif os(OpenBSD)
        // OpenBSD no longer supports extended attributes
        return []
        #else
        #if canImport(Darwin)
        var size = listxattr(path.str, nil, 0, 0)
        #else
        var size = listxattr(path.str, nil, 0)
        #endif
        if size == -1 {
            throw POSIXError(errno, context: "listxattr", path.str)
        }
        guard size > 0 else { return [] }
        let keyList = UnsafeMutableBufferPointer<CChar>.allocate(capacity: size)
        defer { keyList.deallocate() }
        #if canImport(Darwin)
        size = listxattr(path.str, keyList.baseAddress!, size, 0)
        #else
        size = listxattr(path.str, keyList.baseAddress!, size)
        #endif
        if size == -1 {
            throw POSIXError(errno, context: "listxattr", path.str)
        }
        guard size > 0 else { return [] }

        var extendedAttrs: [String] = []
        var current = keyList.baseAddress!
        let end = keyList.baseAddress!.advanced(by: keyList.count)
        while current < end {
            let currentKey = String(cString: current)
            defer { current = current.advanced(by: currentKey.utf8.count) + 1 /* pass null byte */ }
            extendedAttrs.append(currentKey)
        }
        return extendedAttrs
        #endif
    }

    func setExtendedAttribute(_ path: Path, key: String, value: ByteString) throws {
        #if os(Windows)
        // Implement ADS on Windows? See also https://github.com/swiftlang/swift-foundation/issues/1166
        #elseif os(OpenBSD)
        // OpenBSD no longer supports extended attributes
        #else
        try value.bytes.withUnsafeBufferPointer { buf throws -> Void in
            #if canImport(Darwin)
            let result = setxattr(path.str, key, buf.baseAddress, buf.count, 0, XATTR_NOFOLLOW)
            #else
            let result = lsetxattr(path.str, key, buf.baseAddress, buf.count, 0)
            #endif
            guard result == 0 else {
                throw POSIXError(errno, context: "setxattr", path.str, key, value.unsafeStringValue)
            }
        }
        #endif
    }

    func getExtendedAttribute(_ path: Path, key: String) throws -> ByteString? {
        #if os(Windows)
        // Implement ADS on Windows? See also https://github.com/swiftlang/swift-foundation/issues/1166
        return nil
        #elseif os(OpenBSD)
        // OpenBSD no longer supports extended attributes
        return nil
        #else
        var bufferSize = 4096
        repeat {
            var data = [UInt8].init(repeating: 0, count: bufferSize)
            let count: ssize_t = data.withUnsafeMutableBytes {
                #if canImport(Darwin)
                return getxattr(path.str, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                #else
                return lgetxattr(path.str, key, $0.baseAddress, $0.count)
                #endif
            }
            if count < 0 {
                switch errno {
                #if os(Linux) || os(Android)
                case ENODATA:
                    return nil
                #else
                case ENOATTR:
                    return nil
                #endif
                case ERANGE:
                    bufferSize *= 2
                    continue
                default:
                    throw POSIXError(errno, context: "getxattr", path.str, key)
                }
            }
            return ByteString(data[0..<count])
        } while true
        #endif
    }

    func isPathOrAnyAncestorExcludedFromBackup(_ path: Path) throws -> Bool {
        let url = URL(fileURLWithPath: path.str)
        let values = try url.resourceValues(forKeys: Set([URLResourceKey.isExcludedFromBackupKey]))
        return values.isExcludedFromBackup ?? false
    }

    func realpath(_ path: Path) throws -> Path {
        #if os(Windows)
        let handle: HANDLE = path.withPlatformString {
            CreateFileW($0, GENERIC_READ, DWORD(FILE_SHARE_READ), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        if handle == INVALID_HANDLE_VALUE {
            throw POSIXError(ENOENT, context: "realpath", path.str)
        }
        return try handle.closeAfter {
            let dwLength: DWORD = GetFinalPathNameByHandleW(handle, nil, 0, DWORD(FILE_NAME_NORMALIZED))
            return try withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: Int(dwLength)) {
                guard GetFinalPathNameByHandleW(handle, $0.baseAddress!, DWORD($0.count),
                                                DWORD(FILE_NAME_NORMALIZED)) == dwLength - 1 else {
                    throw Win32Error(GetLastError())
                }
                let path = String(platformString: $0.baseAddress!)
                // Drop UNC prefix if present
                if path.hasPrefix(#"\\?\"#) {
                    return Path(path.dropFirst(4))
                }
                return Path(path)
            }
        }
        #else
        guard let result = SWBLibc.realpath(path.str, nil) else { throw POSIXError(errno, context: "realpath", path.str) }
        defer { free(result) }
        return Path(String(cString: result))
        #endif
    }

    func isOnPotentiallyRemoteFileSystem(_ path: Path) -> Bool {
        #if os(macOS)
        var fs = statfs()
        guard statfs(path.str, &fs) == 0 else {
            // Conservatively assume path may be remote.
            return true
        }
        return (fs.f_flags & UInt32(bitPattern: MNT_LOCAL)) == 0
        #else
        return false
        #endif
    }

    func readlink(_ path: Path) throws -> Path {
        #if os(Windows)
        return try Path(fileManager.destinationOfSymbolicLink(atPath: path.str))
        #else
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: Int(PATH_MAX) + 1)
        defer { buf.deallocate() }
        let result = SWBLibc.readlink(path.str, buf, Int(PATH_MAX))
        guard result >= 0 else {
            throw POSIXError(errno, context: "readlink", path.str)
        }
        buf[result] = 0
        return Path(String.init(cString: buf))
        #endif
    }

    func getFreeDiskSpace(_ path: Path) throws -> Int? {
        let systemAttributes = try fileManager.attributesOfFileSystem(forPath: path.str)
        guard let freeSpace = (systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber)?.int64Value else {
            return nil
        }
        return Int(freeSpace)
    }
}


/// Concrete FSProxy implementation which simulates an empty disk.
///
/// This class is thread-safe and supports
/// single-writer, multiple-reader concurrent access.
public class PseudoFS: FSProxy, @unchecked Sendable {
    public var ignoreFileSystemDeviceInodeChanges: Bool {
        fileSystemMode == .deviceAgnostic
    }

    public func move(_ path: Path, to: Path) throws {
        try queue.blocking_sync(flags: .barrier) {
            try _move(path, to: to)
        }
    }

    public func moveInSameVolume(_ path: Path, to: Path) throws {
        try move(path, to: to)
    }

    public func copy(_ path: Path, to: Path) throws {
        // FileManager does not actually copy the root directory, so we should mimic that here.
        if isDirectory(path) {
            for item in try listdir(path) {
                try _copy(path.join(item), to: to.join(item))
            }
        }
        else {
            try _copy(path, to: to)
        }
    }

    public func isSymlink(_ path: Path, _ destinationExists: inout Bool) -> Bool {
        return queue.blocking_sync {
            if case .symlink(let destination)? = getNode(path)?.contents {
                destinationExists = _exists(destination)
                return true
            }
            return false
        }
    }

    public func isExecutable(_ path: Path) throws -> Bool {
        preconditionFailure("TODO: implement when needed")
    }

    public func isFile(_ path: Path) -> Bool {
        preconditionFailure("TODO: implement when needed")
    }

    public func getLinkFileInfo(_ path: Path) throws -> FileInfo {
        preconditionFailure("TODO: implement when needed")
    }

    private func _symlink(_ path: Path, target: Path) throws {
        guard !path.isRoot else { throw POSIXError(EPERM) }

        guard let parent = getNode(path.dirname) else { throw POSIXError(ENOENT) }
        guard case .directory(let directory) = parent.contents else { throw POSIXError(ENOTDIR) }

        // Check if the node exists.
        guard directory.contents[path.basename] == nil else {
            throw POSIXError(EEXIST)
        }

        // Write the symlink.
        directory.contents[path.basename] = Node(.symlink(target), permissions: 0o644, timestamp: getTimestamp(), inode: nextInode())
        parent.timestamp = getTimestamp()
    }

    public func symlink(_ path: Path, target: Path) throws {
        try queue.blocking_sync(flags: .barrier) { try _symlink(path, target: target) }
    }

    public func setIsExcludedFromBackup(_ path: Path, _ value: Bool) throws {
        // No-op (not applicable to PseudoFS)
    }

    public func isPathOrAnyAncestorExcludedFromBackup(_ path: Path) throws -> Bool {
        preconditionFailure("TODO: implement when needed")
    }

    public func realpath(_ path: Path) throws -> Path {
        // TODO: Update this to actually return the link target when we support
        // symlinks; for now it just returns the input, which seems reasonably
        // correct.
        return path
    }

    public func readlink(_ path: Path) throws -> Path {
        return try queue.blocking_sync {
            if case .symlink(let destination)? = getNode(path)?.contents {
                return destination
            }
            throw POSIXError(ENOENT)
        }
    }

    private final class Node {
        /// The actual node data.
        let contents: NodeContents

        /// The permissions on the node.
        var permissions: Int

        /// The last modification timestamp.
        var timestamp: Int

        /// The ownership of the node.
        var owner: Int
        var group: Int

        /// Simulated file system inode information.
        var inode: ino_t

        /// Simulated device information.
        var device: dev_t

        // The extended attributes of the node.
        var xattrs = [String:ByteString]()

        init(_ contents: NodeContents, permissions: Int, timestamp: Int, inode: ino_t, device: dev_t = 1) {
            self.contents = contents
            self.permissions = permissions
            self.timestamp = timestamp
            self.owner = 0
            self.group = 0
            self.inode = inode
            self.device = device
        }
    }
    private enum NodeContents {
        case file(ByteString)
        case directory(DirectoryContents)
        case symlink(Path)
    }
    private final class DirectoryContents {
        var contents: [String: Node]

        init(contents: [String: Node] = [:]) {
            self.contents = contents
        }
    }

    private var queue = SWBQueue(label: "com.apple.dt.SWBUtil.PseudoFS", attributes: .concurrent, autoreleaseFrequency: .workItem)
    private var inodeQueue = SWBQueue(label: "com.apple.dt.SWBUtil.PseudoFS.Inode", attributes: .concurrent, autoreleaseFrequency: .workItem)

    public let fileSystemMode: FileSystemMode

    /// The root filesystem.
    private var root: Node

    public init(ignoreFileSystemDeviceInodeChanges: Bool = UserDefaults.ignoreFileSystemDeviceInodeChanges) {
        self.fileSystemMode = ignoreFileSystemDeviceInodeChanges ? .deviceAgnostic : .fullStat
        root = Node(.directory(DirectoryContents()), permissions: 0o755, timestamp: 0, inode: rootInodeValue)
    }

    public init(fileSystemMode: FileSystemMode) {
        self.fileSystemMode = fileSystemMode
        root = Node(.directory(DirectoryContents()), permissions: 0o755, timestamp: 0, inode: rootInodeValue)
    }

    /// Get a unique monotonic timestamp.
    private func getTimestamp() -> Int {
        writeEpoch += 1
        return writeEpoch
    }
    private var writeEpoch = 0

    /// Get a unique, incrementing device inode value.
    private func nextInode() -> ino_t {
        return inodeQueue.blocking_sync {
            nextInodeValue += 1
            return nextInodeValue
        }
    }
    private let rootInodeValue: ino_t = 1
    private var nextInodeValue: ino_t = 2

    /// Get the node corresponding to get given path.
    private func getNode(_ path: Path) -> Node? {
        func getNodeInternal(_ path: Path) -> Node? {
            // If this is the root node, return it.
            if path.isRoot {
                return root
            }

            // Otherwise, get the parent node.
            guard let parent = getNodeInternal(path.dirname) else {
                return nil
            }

            // If we didn't find a directory, this is an error.
            //
            // FIXME: Error handling.
            guard case .directory(let directory) = parent.contents else {
                log("FIXME: Not a directory: \(path)")
                return nil
            }

            // Return the directory entry.
            return directory.contents[path.basename]
        }

        // Get the node using the normalized path.
        precondition(path.isAbsolute, "input path '\(path.str)' must be absolute")
        return getNodeInternal(path.normalize())
    }

    // MARK: FSProxy Implementation

    public func exists(_ path: Path) -> Bool {
        return queue.blocking_sync { _exists(path) }
    }

    private func _exists(_ path: Path) -> Bool {
        return getNode(path) != nil
    }

    public func isDirectory(_ path: Path) -> Bool {
        return queue.blocking_sync {
            if case .directory? = getNode(path)?.contents {
                return true
            }
            return false
        }
    }

    public func listdir(_ path: Path) throws -> [String] {
        return try queue.blocking_sync {
            guard case .directory(let dirContents)? = getNode(path)?.contents else {
                throw StubError.error("not a directory: \(path.str)")
            }
            return dirContents.contents.map({ $0.key })
        }
    }

    public func createDirectory(_ path: Path, recursive: Bool) throws {
        try queue.blocking_sync(flags: .barrier) {
            try _createDirectory(path, recursive: recursive)
        }
    }

    private func _createDirectory(_ path: Path, recursive: Bool) throws {
        // Get the parent directory node.
        guard let parent = getNode(path.dirname) else {
            // If the parent doesn't exist, and we are recursive, then attempt to create the parent and retry.
            if recursive && !path.isRoot {
                // Attempt to create the parent.
                try _createDirectory(path.dirname, recursive: true)

                // Re-attempt creation, non-recursively.
                try _createDirectory(path, recursive: false)

                // We are done.
                return
            } else {
                // Otherwise, we failed.
                throw POSIXError(ENOENT)
            }
        }

        // Check that the parent is a directory.
        guard case .directory(let directory) = parent.contents else {
            // The parent isn't a directory, this is an error.
            throw POSIXError(ENOTDIR)
        }


        // Check if the node already exists.
        if let node = directory.contents[path.basename] {
            // Verify it is a directory.
            guard case .directory = node.contents else {
                // The path itself isn't a directory, this is an error.
                throw POSIXError(ENOTDIR)
            }

            // We are done.
            return
        }

        // Otherwise, the node does not exist, create it.
        directory.contents[path.basename] = Node(.directory(DirectoryContents()), permissions: 0o755, timestamp: getTimestamp(), inode: nextInode())
        parent.timestamp = getTimestamp()
    }

    public func createTemporaryDirectory(parent: Path) throws -> Path {
        let path = parent.join("swbuild.tmp.\(UUID().uuidString)")
        try createDirectory(path, recursive: true)
        return path
    }

    public func read<T>(_ path: Path, read: (FileHandle) throws -> T) throws -> T {
        return try withTemporaryDirectory { dir in
            let temporaryFilePath = dir.join(path.basename)
            try localFS.write(temporaryFilePath, contents: self.read(path))
            do {
                let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: temporaryFilePath.str))
                return try read(fh)
            } catch {
                throw StubError.error("Cannot open file handle for file at path: \(temporaryFilePath.str): \(error.localizedDescription)")
            }
        }
    }

    private func _read(_ path: Path) throws -> ByteString {
        guard let node = getNode(path) else { throw POSIXError(ENOENT) }
        guard case .file(let contents) = node.contents else { throw POSIXError(EISDIR) }
        return contents
    }

    public func read(_ path: Path) throws -> ByteString {
        return try queue.blocking_sync { try _read(path) }
    }

    public func readMemoryMapped(_ path: Path) throws -> Data {
        throw StubError.error("unimplemented")
    }

    public func write(_ path: Path, contents: (FileDescriptor) async throws -> Void) async throws {
        throw StubError.error("unimplemented")
    }

    private func _copy(_ path: Path, to: Path) throws {
        func copyInfo(from node: Node, to: Path) throws {
            // It's important to copy over key information that FileManager does as well!
            try setFileTimestamp(to, timestamp: node.timestamp)
            try setFilePermissions(to, permissions: node.permissions)
        }

        guard let node = getNode(path) else { throw POSIXError(ENOENT) }
        switch node.contents {
        case .file(let contents):
            try _write(to, contents: contents, append: false)
            try copyInfo(from: node, to: to)
        case .directory(let contents):
            try createDirectory(to, recursive: true)

            for (p, _) in contents.contents {
                try _copy(path.join(p), to: to.join(p))
            }

            // Do this **after** processing the children to ensure things like modification times are copied properly.
            try copyInfo(from: node, to: to)
        case .symlink(let destination):
            try _symlink(to, target: destination)
            try copyInfo(from: node, to: to)
        }
    }

    public func _move(_ path: Path, to: Path) throws {
        guard !path.isRoot && !to.isRoot else { throw POSIXError(EPERM) }

        guard let fromNode = getNode(path) else { throw POSIXError(ENOENT) }
        guard let fromParentNode = getNode(path.dirname) else {
            fatalError("unable to move file: '\(path.str)' to '\(to.str)' (Surprisingly could not get node for the original parent directory)")
        }
        guard case .directory(let fromParentContents) = fromParentNode.contents else {
            fatalError("unable to move file: '\(path.str)' to '\(to.str)' (Surprisingly the original parent is not a directory)")
        }
        guard let toParentNode = getNode(to.dirname) else { throw POSIXError(ENOENT) }

        // Parent of the location we're moving to must be a directory
        guard case let .directory(toParentContents) = toParentNode.contents else {
            throw POSIXError(ENOTDIR)
        }

        // Can replace an existing file (with a file) but not a directory
        if let toNode = toParentContents.contents[to.basename] {
            guard case .file = fromNode.contents, case .file = toNode.contents else {
                throw POSIXError(EEXIST)
            }
        }

        let newTimestamp = getTimestamp()
        toParentContents.contents[to.basename] = fromNode
        toParentNode.timestamp = newTimestamp
        fromParentContents.contents.removeValue(forKey: path.basename)
        fromParentNode.timestamp = newTimestamp
    }

    private func _write(_ path: Path, contents: ByteString, append: Bool) throws {
        guard !path.isRoot else { throw POSIXError(EPERM) }

        guard let parent = getNode(path.dirname) else { throw POSIXError(ENOENT) }
        guard case .directory(let directory) = parent.contents else { throw POSIXError(ENOTDIR) }

        let existingContents: ByteString

        // Check if the node exists.
        if let node = directory.contents[path.basename] {
            guard case let .file(fileContents) = node.contents else { throw POSIXError(EISDIR) }
            existingContents = append ? fileContents : ByteString()
        }
        else {
            existingContents = ByteString()
        }

        // Write the file.
        directory.contents[path.basename] = Node(.file(existingContents + contents), permissions: 0o644, timestamp: getTimestamp(), inode: nextInode())
        parent.timestamp = getTimestamp()
    }

    public func write(_ path: Path, contents: ByteString, atomically: Bool) throws {
        try queue.blocking_sync(flags: .barrier) { try _write(path, contents: contents, append: false) }
    }

    public func append(_ path: Path, contents: ByteString) throws {
        try queue.blocking_sync(flags: .barrier) { try _write(path, contents: contents, append: true) }
    }

    public func remove(_ path: Path) throws {
        try queue.blocking_sync(flags: .barrier) {
            guard !path.isRoot else { throw POSIXError(EPERM) }
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            guard case .file = node.contents else { throw POSIXError(EISDIR) }

            // Remove the file by getting the node for its parent directory, and removing it.
            // The errors below all indicate a problem with the PseudoFS state.
            guard let parent = getNode(path.dirname) else {
                fatalError("unable to remove file: '\(path.str)' (Surprisingly could not get node for its parent directory)")
            }
            guard case .directory(let directory) = parent.contents else {
                fatalError("unable to remove file: '\(path.str)' (Surprisingly its parent node is not a directory)")
            }
            guard directory.contents[path.basename] != nil else {
                fatalError("unable to remove file: '\(path.str)' (Surprisingly it does not exist in the node contents of its parent directory's node)")
            }
            directory.contents.removeValue(forKey: path.basename)
            parent.timestamp = getTimestamp()
        }
    }

    public func removeDirectory(_ path: Path) throws {
        try queue.blocking_sync(flags: .barrier) {
            guard !path.isRoot else { throw POSIXError(EPERM) }

            // Get the parent node's content if its a directory.
            guard let parent = getNode(path.dirname),
                  case .directory(let contents) = parent.contents else {
                return
            }
            // Set it to nil to release the contents.
            contents.contents[path.basename] = nil
        }
    }

    public func getFileInfo(_ path: Path) throws -> FileInfo {
        return try queue.blocking_sync {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            switch node.contents {
            case .file(let contents):
                var info = stat()
                #if os(Windows)
                info.st_mtimespec = timespec(tv_sec: Int64(node.timestamp), tv_nsec: 0)
                #else
                info.st_mtimespec = timespec(tv_sec: time_t(node.timestamp), tv_nsec: 0)
                #endif
                info.st_size = off_t(contents.bytes.count)
                info.st_dev = node.device
                info.st_ino = node.inode
                return createFileInfo(info)
            case .directory(let dir):
                var info = stat()
                #if os(Windows)
                info.st_mode = UInt16(ucrt.S_IFDIR)
                info.st_mtimespec = timespec(tv_sec: Int64(node.timestamp), tv_nsec: 0)
                #else
                info.st_mode = S_IFDIR
                info.st_mtimespec = timespec(tv_sec: time_t(node.timestamp), tv_nsec: 0)
                #endif
                info.st_size = off_t(dir.contents.count)
                info.st_dev = node.device
                info.st_ino = node.inode
                return createFileInfo(info)
            case .symlink(_):
                var info = stat()
                #if os(Windows)
                info.st_mode = UInt16(S_IFLNK)
                info.st_mtimespec = timespec(tv_sec: Int64(node.timestamp), tv_nsec: 0)
                #else
                info.st_mode = S_IFLNK
                info.st_mtimespec = timespec(tv_sec: time_t(node.timestamp), tv_nsec: 0)
                #endif
                info.st_size = off_t(0)
                info.st_dev = node.device
                info.st_ino = node.inode
                return createFileInfo(info)
            }
        }
    }

    public func setFilePermissions(_ path: Path, permissions: Int) throws {
        try queue.blocking_sync(flags: .barrier) {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            node.permissions = permissions
        }
    }

    public func getFilePermissions(_ path: Path) throws -> Int {
        return try queue.blocking_sync {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            return node.permissions
        }
    }

    public func setFileOwnership(_ path: Path, owner: Int, group: Int) throws {
        try queue.blocking_sync(flags: .barrier) {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            node.owner = owner
            node.group = group
        }
    }

    public func getFileOwnership(_ path: Path) throws -> (owner: Int, group: Int) {
        return try queue.blocking_sync {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            return (node.owner, node.group)
        }
    }

    public func listExtendedAttributes(_ path: Path) throws -> [String] {
        try queue.blocking_sync {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            return Array(node.xattrs.keys)
        }
    }

    public func setExtendedAttribute(_ path: Path, key: String, value: ByteString) throws {
        try queue.blocking_sync(flags: .barrier) {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            node.xattrs[key] = value
        }
    }

    public func getExtendedAttribute(_ path: Path, key: String) throws -> ByteString? {
        return try queue.blocking_sync {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            return node.xattrs[key]
        }
    }

    public func touch(_ path: Path) throws {
        try queue.blocking_sync(flags: .barrier) {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            node.timestamp = numericCast(time(nil))
        }
    }

    public func setFileTimestamp(_ path: Path, timestamp: Int) throws {
        try queue.blocking_sync(flags: .barrier) {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            node.timestamp = timestamp
        }
    }

    public func getFileTimestamp(_ path: Path) throws -> Int {
        return try queue.blocking_sync {
            guard let node = getNode(path) else { throw POSIXError(ENOENT) }
            return node.timestamp
        }
    }

    @discardableResult public func traverse<T>(_ path: Path, _ f: (Path) throws -> T?) throws -> [T] {
        var results: [T] = []
        for p in try listdir(path) {
            let nextPath = path.join(p)
            if let r = try f(nextPath) {
                results.append(r)
            }

            if isDirectory(nextPath) {
                try results.append(contentsOf: traverse(nextPath, f))
            }
        }
        return results
    }

    public func isOnPotentiallyRemoteFileSystem(_ path: Path) -> Bool {
        false
    }
}

/// Public access to the local FS proxy.
public let localFS: any FSProxy = LocalFS(fileSystemMode: UserDefaults.fileSystemMode)

/// Hook for testing to create FS instances.
public func createFS(simulated: Bool, fileSystemMode: FileSystemMode) -> any FSProxy {
    if simulated {
        return PseudoFS(fileSystemMode: fileSystemMode)
    } else {
        return LocalFS(fileSystemMode: fileSystemMode)
    }
}

/// Hook for testing to create FS instances.
public func createFS(simulated: Bool, ignoreFileSystemDeviceInodeChanges: Bool) -> any FSProxy {
    if simulated {
        return PseudoFS(ignoreFileSystemDeviceInodeChanges: ignoreFileSystemDeviceInodeChanges)
    } else {
        return LocalFS(ignoreFileSystemDeviceInodeChanges: ignoreFileSystemDeviceInodeChanges)
    }
}

fileprivate extension stat {
    static func ==(lhs: stat, rhs: stat) -> Bool {
        return (
            lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_uid == rhs.st_uid &&
            lhs.st_gid == rhs.st_gid &&
            lhs.st_rdev == rhs.st_rdev &&
            lhs.st_atimespec == rhs.st_atimespec &&
            lhs.st_mtimespec == rhs.st_mtimespec &&
            lhs.st_ctimespec == rhs.st_ctimespec &&
            lhs.st_size == rhs.st_size)
    }
}

extension timespec: Equatable {
    public static func ==(lhs: timespec, rhs: timespec) -> Bool {
        return lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
    }
}

#if os(Windows)
public struct timespec: Sendable {
    public let tv_sec: Int64
    public let tv_nsec: Int64
}

extension stat {
    public var st_atim: timespec {
        get { timespec(tv_sec: st_atime, tv_nsec: 0) }
        set { st_atime = newValue.tv_sec }
    }

    public var st_mtim: timespec {
        get { timespec(tv_sec: st_mtime, tv_nsec: 0) }
        set { st_mtime = newValue.tv_sec }
    }

    public var st_ctim: timespec {
        get { timespec(tv_sec: st_ctime, tv_nsec: 0) }
        set { st_ctime = newValue.tv_sec }
    }
}
#endif

#if !canImport(Darwin)
extension stat {
    public var st_atimespec: timespec {
        get { st_atim }
        set { st_atim = newValue }
    }

    public var st_mtimespec: timespec {
        get { st_mtim }
        set { st_mtim = newValue }
    }

    public var st_ctimespec: timespec {
        get { st_ctim }
        set { st_ctim = newValue }
    }
}
#endif

#if os(Windows)
extension HANDLE {
    /// Runs a closure and then closes the HANDLE, even if an error occurs.
    ///
    /// - Parameter body: The closure to run.
    ///   If the closure throws an error,
    ///   this method closes the file descriptor before it rethrows that error.
    ///
    /// - Returns: The value returned by the closure.
    ///
    /// If `body` throws an error
    /// or an error occurs while closing the file descriptor,
    /// this method rethrows that error.
    public func closeAfter<R>(_ body: () throws -> R) throws -> R {
        // No underscore helper, since the closure's throw isn't necessarily typed.
        let result: R
        do {
            result = try body()
        } catch {
            _ = try? self.close() // Squash close error and throw closure's
            throw error
        }
        try self.close()
        return result
    }

    fileprivate func close() throws {
        if !CloseHandle(self) {
            throw Win32Error(GetLastError())
        }
    }
}
#endif

extension FileDescriptor {
    /// Runs a closure and then closes the FileDescriptor, even if an error occurs.
    ///
    /// - Parameter body: The closure to run.
    ///   If the closure throws an error,
    ///   this method closes the file descriptor before it rethrows that error.
    ///
    /// - Returns: The value returned by the closure.
    ///
    /// If `body` throws an error
    /// or an error occurs while closing the file descriptor,
    /// this method rethrows that error.
    public func closeAfter<R>(_ body: () async throws -> R) async throws -> R {
        // No underscore helper, since the closure's throw isn't necessarily typed.
        let result: R
        do {
            result = try await body()
        } catch {
            _ = try? self.close() // Squash close error and throw closure's
            throw error
        }
        try self.close()
        return result
    }
}
