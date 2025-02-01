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

#if canImport(AppleArchive) && canImport(System)
import AppleArchive
import System
public import struct Foundation.UUID

/// A simple interface over a create-or-update compressed Apple Archive (.aar) file protected by an exclusive file lock, for archiving an XCBuildData directory.
///
/// This class is thread-safe and access to the underlying archive file is atomic across multiple processes.
public final class XCBuildDataArchive: Sendable {
    /// The path to the .yaa archive file which will be written to.
    public let archiveFilePath: Path

    public init(filePath: Path) {
        self.archiveFilePath = filePath
    }

    /// Adds the contents of the specified build data directory into the archive. The directory argument is expected to be the path to an XCBuildData directory (which contains the manifest, build description, build database, and other auxiliary files).
    public func appendBuildDataDirectory(from buildDataDirectory: Path, uuid: UUID) throws {
        if buildDataDirectory.basename != "XCBuildData" {
            throw StubError.error("\(buildDataDirectory.str) is not an XCBuildData directory")
        }
        return try withTemporaryDirectory { tmpDir in
            let tempDirectory = tmpDir.join(uuid.description)
            try localFS.copy(buildDataDirectory, to: tempDirectory)
            try appendDirectoryContents(from: tempDirectory)
        }
    }

    private func appendDirectoryContents(from sourcePath: Path) throws {
        // Append to the archive if it already exists -- this is necessary in order to support cases
        // where xcodebuild invokes another instance of itself in a shell script. We use exclusive
        // locks to guarantee integrity of the archive, but in practice the locking should only ever
        // come into play when there are 3 or more xcodebuild processes (the top level process plus
        // 2 or more potentially concurrent xcodebuilds running in shell scripts as part of the top
        // level build). Very few projects do this, so there shouldn't be a general efficiency concern
        // regarding the blocking locks.
        let exists: Bool
        let fd: FileDescriptor
        do {
            fd = try FileDescriptor.open(FilePath(archiveFilePath.str), .writeOnly, options: [.create, .exclusiveCreate, .exclusiveLock], permissions: FilePermissions([.ownerReadWrite, .groupRead, .otherRead]))
            exists = false
        } catch Errno.fileExists {
            fd = try FileDescriptor.open(FilePath(archiveFilePath.str), .readWrite, options: [.exclusiveLock])
            exists = true
        }

        try fd.closeAfter {
            try ArchiveByteStream.withFileStream(fd: fd, automaticClose: false) { writeFileStream in
                guard let compressStream = exists
                        ? ArchiveByteStream.compressionStream(appendingTo: writeFileStream)
                        : ArchiveByteStream.compressionStream(using: .lzfse, writingTo: writeFileStream) else {
                    throw StubError.error("Unable to create compression stream for \(exists ? "existing" : "new") file: \(archiveFilePath.str)")
                }

                defer {
                    try? compressStream.close()
                }

                guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
                    throw StubError.error("Unable to create encode stream for \(exists ? "existing" : "new") file: \(archiveFilePath.str)")
                }

                defer {
                    try? encodeStream.close()
                }

                // Only store the most minimal info: entry type, path, symlink info, and data.
                // Other attributes like uid, gid, timestamps, etc., are not of interest here.
                // See AADefs.h from the AppleArchive headers for the key meanings.
                guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DAT") else {
                    throw StubError.error("Unable to create archive key set")
                }

                try encodeStream.writeDirectoryContents(archiveFrom: FilePath(sourcePath.dirname.str), path: FilePath(sourcePath.basename), keySet: keySet)
            }
        }
    }
}
#endif
