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

import Foundation

import Testing
import SWBLibc
import SWBTestSupport
@_spi(TestSupport) import SWBUtil

@Suite fileprivate struct FSProxyTests {

#if !os(Windows)
    /// Utility method to check the modes of an item at the given path.
    private func checkModes(_ path: Path, modes: [mode_t], sourceLocation: SourceLocation = #_sourceLocation) {
        var sbuf = stat()
        let rv = stat(path.str, &sbuf)
        guard rv == 0 else {
            Issue.record("Invalid stat return value \(rv) for \(path)", sourceLocation: sourceLocation)
            return
        }
        for mode in modes {
            #expect(sbuf.st_mode & mode > 0, "mode \(mode) not found on \(path)", sourceLocation: sourceLocation)
        }
    }
#endif

    // MARK: LocalFS Tests

    @Test(.skipHostOS(.windows)) // FIXME: error handling is different on Windows
    func localCreateDirectory() throws {
        try withTemporaryDirectory { (tmpDir: Path) in
            // Create a directory inside the tmpDir.
            do {
                let testPath = tmpDir.join("new-dir")
                #expect(!localFS.exists(testPath))
                try localFS.createDirectory(testPath)
#if !os(Windows)
                checkModes(testPath, modes: [S_IRWXU, S_IRWXG, S_IRWXO])
#endif
                #expect(localFS.exists(testPath))
                #expect(localFS.isDirectory(testPath))
            }

            // Create a directory hierarchy in the tmpDir.
            do {
                let testPath = tmpDir.join("another-new-dir/with-a-subdir")
                #expect(!localFS.exists(testPath))
                try localFS.createDirectory(testPath, recursive: true)
                #expect(localFS.exists(testPath))
                #expect(localFS.isDirectory(testPath))

                // Check that creating the (now existing) directory again succeeds.
                try localFS.createDirectory(testPath, recursive: true)
            }

            // Test that creating a directory through a symbolic link to another directory works.
            do {
                let dirPath = tmpDir.join("target-dir")
                try localFS.createDirectory(dirPath, recursive: true)
                #expect(localFS.exists(dirPath))
                #expect(localFS.isDirectory(dirPath))
                let symlinkPath = tmpDir.join("symlink")
                try localFS.symlink(symlinkPath, target: dirPath)
                #expect(localFS.exists(symlinkPath))
                var destinationExists = false
                #expect(localFS.isSymlink(symlinkPath, &destinationExists))
                #expect(destinationExists)
                #expect(localFS.isDirectory(symlinkPath))

                let testPath = symlinkPath.join("symlink-dir")
                try localFS.createDirectory(testPath, recursive: true)
                #expect(localFS.exists(testPath))
                #expect(localFS.isDirectory(testPath))

                // Also test that we can create the directory *at* the symlink location - which should succeed since it points to an existing directory.
                try localFS.createDirectory(symlinkPath, recursive: true)
            }

            // Test that creating a directory where there is a file fails.
            do {
                let filePath = tmpDir.join("some-file")
                #expect(!localFS.exists(filePath))
                try localFS.write(filePath, contents: ByteString([]))
                #expect(localFS.exists(filePath))
                #expect(!localFS.isDirectory(filePath))
                var didThrow = false
                do {
                    try localFS.createDirectory(filePath)
                }
                catch {
                    didThrow = true
                    #expect(error.localizedDescription == "File exists but is not a directory: \(filePath.str)")
                }
                #expect(didThrow)

                // Also try creating a directory which is a child of the file.
                let dirPath = filePath.join("bad-dir")
                didThrow = false
                do {
                    try localFS.createDirectory(dirPath, recursive: true)
                }
                catch {
                    didThrow = true
                    #expect(error.localizedDescription == "File exists but is not a directory: \(filePath.str)")
                }
                #expect(didThrow)
            }

            // Test that creating a directory through a broken symlink fails.
            do {
                let symlinkPath = tmpDir.join("broken-symlink")
                #expect(!localFS.exists(symlinkPath))
                try localFS.symlink(symlinkPath, target: Path("/no/such/file/here"))
                var destinationExists = false
                #expect(localFS.isSymlink(symlinkPath, &destinationExists))
                #expect(!destinationExists)
                var didThrow = false
                do {
                    try localFS.createDirectory(symlinkPath)
                }
                catch {
                    didThrow = true
                    #expect(error.localizedDescription == "File is a broken symbolic link: \(symlinkPath.str)")
                }
                #expect(didThrow)

                // Also try creating a directory which is a child of the broken symlink.
                let dirPath = symlinkPath.join("bad-dir")
                didThrow = false
                do {
                    try localFS.createDirectory(dirPath, recursive: true)
                }
                catch {
                    didThrow = true
                    #expect(error.localizedDescription == "File is a broken symbolic link: \(symlinkPath.str)")
                }
                #expect(didThrow)
            }

            // Test that creating a directory through a symlink to a file fails.
            do {
                let filePath = tmpDir.join("another-file")
                #expect(!localFS.exists(filePath))
                try localFS.write(filePath, contents: ByteString([]))
                #expect(localFS.exists(filePath))
                #expect(!localFS.isDirectory(filePath))
                let symlinkPath = tmpDir.join("symlink-to-file")
                #expect(!localFS.exists(symlinkPath))
                try localFS.symlink(symlinkPath, target: filePath)
                var destinationExists = false
                #expect(localFS.isSymlink(symlinkPath, &destinationExists))
                #expect(destinationExists)
                #expect(!localFS.isDirectory(symlinkPath))
                var didThrow = false
                do {
                    try localFS.createDirectory(symlinkPath)
                }
                catch {
                    didThrow = true
                    #expect(error.localizedDescription == "File is a symbolic link which references a path which is not a directory: \(symlinkPath.str)")
                }
                #expect(didThrow)

                // Also try creating a directory which is a child of the symlink-to-a-file.
                let dirPath = symlinkPath.join("bad-dir")
                didThrow = false
                do {
                    try localFS.createDirectory(dirPath, recursive: true)
                }
                catch {
                    didThrow = true
                    #expect(error.localizedDescription == "File exists but is not a directory: \(symlinkPath.str)")
                }
                #expect(didThrow)
            }

            // Test that trying to recursively create a directory with an empty path fails.
            do {
                let filePath = Path("")
                #expect {
                    try localFS.createDirectory(filePath, recursive: true)
                } throws: { error in
                    error.localizedDescription == "Cannot recursively create directory at non-absolute path: "
                }
            }

            // Test that trying to recursively create a directory with a relative path fails.
            do {
                let filePath = Path("foo/bar/baz")
                #expect {
                    try localFS.createDirectory(filePath, recursive: true)
                } throws: { error in
                    error.localizedDescription == "Cannot recursively create directory at non-absolute path: foo/bar/baz"
                }
            }
        }
    }

    @Test
    func listDir() throws {
        let fs = localFS
        try withTemporaryDirectory { tmpDir in
            try fs.createDirectory(tmpDir.join("new-dir"))
            try fs.write(tmpDir.join("new-file"), contents: ByteString([]))
            #expect(try Set(["new-dir", "new-file"]) == Set(fs.listdir(tmpDir)))
        }
    }

    @Test
    func localReadFile() throws {
        try withTemporaryDirectory { tmpDir in
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let testDataPath = tmpDir.join("test-data.txt")
            try testData.write(toFile: testDataPath.str, atomically: false, encoding: String.Encoding.utf8)
            #expect(try ByteString(testData) == localFS.read(testDataPath))
            #expect(try ByteString(testData) == localFS.read(testDataPath))
        }
    }

    @Test
    func localReadMissing() {
        #expect(throws: (any Error).self) {
            try localFS.read(Path("/tmp/is/not/not/tmp"))
        }
    }

    @Test
    func localWriteFile() throws {
        try withTemporaryDirectory { tmpDir in
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let testDataPath = tmpDir.join("test-data.txt")
            try localFS.write(testDataPath, contents: ByteString(testData))
            let data = try localFS.read(testDataPath)
            #expect(data == ByteString(testData))
        }
    }

    @Test
    func localAppendFile() throws {
        try withTemporaryDirectory { tmpDir in
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let testDataPath = tmpDir.join("test-data.txt")
            try localFS.append(testDataPath, contents: ByteString(testData))
            let data = try localFS.read(testDataPath)
            #expect(data == ByteString(testData))

            try localFS.append(testDataPath, contents: ByteString(testData))
            let moreData = try localFS.read(testDataPath)
            #expect(moreData == ByteString(testData + testData))
        }
    }

    @Test
    func localCopyFile() throws {
        try withTemporaryDirectory { tmpDir in
            try _testCopyFile(localFS, basePath: tmpDir)
        }
    }

    @Test
    func localCopyTree() throws {
        try withTemporaryDirectory { tmpDir in
            try _testCopyTree(localFS, basePath: tmpDir)
        }
    }

    @Test
    func localMove() throws {
        try withTemporaryDirectory { tmpDir in
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let testDataPath = tmpDir.join("test-data.txt")
            let testDataPathDst = tmpDir.join("test-data-2.txt")
            let permissions: Int = 0o755

            try localFS.write(testDataPath, contents: ByteString(testData))
            try localFS.setFilePermissions(testDataPath, permissions: permissions)

            try localFS.move(testDataPath, to: testDataPathDst)

            #expect(!localFS.exists(testDataPath))
            #expect(try ByteString(testData) == localFS.read(testDataPathDst))

            // POSIX permissions model is inapplicable to Windows
            if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
                return
            }

            #expect(try localFS.getFilePermissions(testDataPathDst) == permissions)
        }
    }

    @Test(.requireHostOS(.macOS)) // `moveInSameVolume` just does nothing on Linux, apparently
    func localMoveInSameVolume() throws {
        let fs = localFS
        try withTemporaryDirectory(fs: fs) { tmpDirPath in
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let testDataPath = tmpDirPath.join("test-data.txt")
            let testDataPathDst = tmpDirPath.join("test-data-2.txt")
            let permissions: Int = 0o755

            try fs.write(testDataPath, contents: ByteString(testData))
            try fs.write(testDataPathDst, contents: ByteString(""))
            try fs.setFilePermissions(testDataPath, permissions: permissions)

            try fs.moveInSameVolume(testDataPath, to: testDataPathDst)

            #expect(!fs.exists(testDataPath), "No file should exist at \(testDataPath.str)")
            #expect(try fs.getFilePermissions(testDataPathDst) == permissions)
            #expect(try ByteString(testData) == fs.read(testDataPathDst))
        }
    }

    @Test
    func localRemoveFile() throws {
        try withTemporaryDirectory { tmpDir in
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let testDataPath = tmpDir.join("test-data.txt")
            try localFS.write(testDataPath, contents: ByteString(testData))
            #expect(localFS.exists(testDataPath))
            let data = try localFS.read(testDataPath)
            #expect(data == ByteString(testData))

            // Now remove the file.
            try localFS.remove(testDataPath)
            #expect(!localFS.exists(testDataPath))
        }
    }

    @Test(.skipHostOS(.windows)) // POSIX permissions model is inapplicable to Windows
    func localSetPermissions() throws {
        try withTemporaryDirectory { tmpDir in
            // Test setting file permissions.
            let execPath = tmpDir.join("script.sh")
            try localFS.write(execPath, contents: [])
            #expect(try !localFS.isExecutable(execPath))

            try localFS.setFilePermissions(execPath, permissions: 0o755)
            #expect(try localFS.getFilePermissions(execPath) == 0o755)
            #expect(try localFS.isExecutable(execPath))
        }
    }

    @Test
    func localTraverse() throws {
        try withTemporaryDirectory { tmpDir in
            let p0 = tmpDir.join("a")
            try localFS.write(p0, contents: [])

            let p1 = tmpDir.join("b")
            try localFS.createDirectory(p1)

            let p2 = p1.join("c")
            try localFS.write(p2, contents: [])

            var seen: [Path] = []
            try localFS.traverse(tmpDir) {
                seen.append($0)
            }

            // One visit for each path
            #expect(seen.count == Set(seen).count)

            // Order doesn't matter
            #expect(Set(seen) == Set([p0, p1, p2]))
        }
    }

    @Test
    func localSymlinks() throws {
        try withTemporaryDirectory { (tmpDir: Path) in
            let realTmpPath = try localFS.realpath(tmpDir)

            let file = realTmpPath.join("file")
            let data = ByteString(encodingAsUTF8: "foo")
            try localFS.write(file, contents: data)

            #expect(try file == localFS.realpath(file))

            let fileInfo = try localFS.getFileInfo(file)
            #expect(!fileInfo.isSymlink)

            let linkFileInfo = try localFS.getLinkFileInfo(file)
            #expect(fileInfo.statBuf.st_ino == linkFileInfo.statBuf.st_ino)
            #expect(!linkFileInfo.isSymlink)

            // Test absolute and relative targets
            for target in [file, Path(file.basename)] {
                let sym = realTmpPath.join("sym")

                if localFS.exists(sym) {
                    try localFS.remove(sym)
                }

                try localFS.symlink(sym, target: target)
                #expect(try (target.isAbsolute ? target : realTmpPath.join(target)) == localFS.realpath(sym))
                #expect(try localFS.read(sym) == data)

                let symFileInfo = try localFS.getFileInfo(sym)
                #expect(symFileInfo.statBuf.st_ino == fileInfo.statBuf.st_ino)
                #expect(!symFileInfo.isSymlink)

                let symLinkFileInfo = try localFS.getLinkFileInfo(sym)
                #expect(symLinkFileInfo.isSymlink)
            }

            #expect(performing: {
                _ = try localFS.realpath(realTmpPath.join("nonexistent"))
            }, throws: { error in
                (error as? SWBUtil.POSIXError)?.code == ENOENT
            })
        }
    }

    @Test
    func modificationTimestamp() throws {
        let filePath = Path.root.join("file.txt")
        let fs = PseudoFS()

        try fs.write(filePath, contents: ByteString())

        #expect(try fs.getFileInfo(filePath).modificationTimestamp == 1)
        #expect(try fs.getFileInfo(.root).modificationTimestamp == 2)

        try fs.write(filePath, contents: ByteString())
        #expect(try fs.getFileInfo(filePath).modificationTimestamp == 3)
        #expect(try fs.getFileInfo(.root).modificationTimestamp == 4)
    }

    @Test
    func localModificationDate() throws {
        let fs = localFS

        try withTemporaryDirectory { (tmpDir: Path) in
            let filePath = tmpDir.join("file.txt")
            try fs.write(filePath, contents: ByteString())

            let fsModDate = try fs.getFileInfo(filePath).modificationDate
            let fileAtts = try FileManager.default.attributesOfItem(atPath: filePath.str)
            let fileMgrModDate = try #require(fileAtts[FileAttributeKey.modificationDate] as? Date)

            // not working on Windows for some reason
            let hostOS = try ProcessInfo.processInfo.hostOperatingSystem()
            withKnownIssue {
                #expect(fsModDate == fileMgrModDate)
            } when: { hostOS == .windows }
        }
    }

    @Test
    func removeDirectory() throws {
        try withTemporaryDirectory { tmpDir in
            removeFileTreeTester(fs: localFS, basePath: tmpDir)
        }
    }

    @Test
    func localFileOwnership() throws {
        let current_uid = ProcessInfo.processInfo.userID
        let current_gid = ProcessInfo.processInfo.groupID
        try withTemporaryDirectory { tmpDir in
            let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
            let testDataPath = tmpDir.join("test-data.txt")
            try localFS.write(testDataPath, contents: ByteString(testData))

            let parentDirOwnership = try localFS.getFileOwnership(tmpDir)
            let ownership = try localFS.getFileOwnership(testDataPath)

            // The owner of newly created files is guaranteed to the be process effective UID on Linux. It is not documented on BSDs but generally also expected to be the process effective UID.
            #expect(current_uid == ownership.owner)

            // Considering the following man page documentation for open(2):
            //   [Darwin/BSD] When a new file is created it is given the group of the directory which contains it.
            //   [Linux] The group ownership (group ID) of the new file is set either to the effective group ID of the process (System V semantics) or to the group ID of the parent directory (BSD semantics). On Linux, the behavior depends on whether the set-group-ID mode bit is set on the parent directory: if that bit is set, then BSD semantics apply; otherwise, System V semantics apply. For some filesystems, the behavior also depends on the bsdgroups and sysvgroups mount options described in mount(8).
            // ...and the following man page documentation for mkdir(2):
            //   [Darwin/BSD] The directory's group ID is set to that of the parent directory in which it is created.
            //   [Linux] If the directory containing the file has the set-group-ID bit set, or if the filesystem is mounted with BSD group semantics (mount -o bsdgroups or, synonymously mount -o grpid), the new directory will inherit the group ownership from its parent; otherwise it will be owned by the effective group ID of the process.
            switch try ProcessInfo.processInfo.hostOperatingSystem() {
            case .android, .linux:
                // This will _usually_ be correct on Linux-derived OSes (see above), but not always.
                #expect(current_gid == ownership.group)
            case .macOS, .iOS, .tvOS, .watchOS, .visionOS:
                #expect(parentDirOwnership.group == ownership.group)
            case .windows:
                // POSIX permissions don't exist, so everything is hardcoded to zero.
                #expect(current_gid == 0)
                #expect(ownership.group == 0)
            case .unknown:
                break
            }

            try localFS.setFileOwnership(testDataPath, owner: current_uid, group: current_gid)
            let ownershipAfterChange = try localFS.getFileOwnership(testDataPath)
            #expect(current_uid == ownershipAfterChange.owner)
            #expect(current_gid == ownershipAfterChange.group)
        }
    }

    @Test(.requireHostOS(.macOS))
    func localIsExcludedFromBackup() throws {
        func check(sourceLocation: SourceLocation = #_sourceLocation, f: (_ path: Path, _ subPath: Path) throws -> Void) throws {
            let tmpDir = try NamedTemporaryDirectory(excludeFromBackup: false)
            let path = tmpDir.path
            let subPath = path.join("sub")
            try localFS.createDirectory(subPath)

            #expect(throws: Never.self, sourceLocation: sourceLocation) {
                try f(path, subPath)
            }
            try tmpDir.remove()
        }

        func setExcluded(_ path: Path, _ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(throws: Never.self, sourceLocation: sourceLocation) {
                try localFS.setIsExcludedFromBackup(path, value)
            }
        }

        func checkExcluded(_ path: Path, _ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(try localFS.isPathOrAnyAncestorExcludedFromBackup(path) == value, sourceLocation: sourceLocation)
        }

        // Nothing is excluded by default
        try check { path, subPath in
            try checkExcluded(path, false)
            try checkExcluded(subPath, false)
        }

        // Excluding a subpath should not exclude its parent
        try check { path, subPath in
            try setExcluded(subPath, true)
            try checkExcluded(path, false)
            try checkExcluded(subPath, true)
        }

        // Excluding a parent should implicitly exclude a subpath
        try check { path, subPath in
            try setExcluded(path, true)
            try checkExcluded(path, true)
            try checkExcluded(subPath, true)
        }

        // If a parent path is excluded, setting a subpath to not be excluded should have no effect
        try check { path, subPath in
            try setExcluded(path, true)
            try setExcluded(subPath, false)
            try checkExcluded(path, true)
            try checkExcluded(subPath, true)
        }

        // If a subpath is excluded, setting a parent path to not be excluded should not change the subpath's setting
        try check { path, subPath in
            try setExcluded(subPath, true)
            try setExcluded(path, false)
            try checkExcluded(path, false)
            try checkExcluded(subPath, true)
        }
    }

    @Test(.skipHostOS(.windows))
    func extendedAttributesSupport() throws {
        try withTemporaryDirectory { (tmpDir: Path) in
            // Many filesystems on other platforms (e.g. various non-ext4 temporary filesystems on Linux) don't support xattrs and will return ENOTSUP.
            // In particular, tmpfs doesn't support xattrs on Linux unless `CONFIG_TMPFS_XATTR` is enabled in the kernel config.
            if try ProcessInfo.processInfo.hostOperatingSystem() == .linux {
                do {
                    try localFS.setExtendedAttribute(tmpDir, key: "user.test", value: [])
                } catch let error as SWBUtil.POSIXError where error.code == ENOTSUP {
                    return
                }
            }

            let testDataPath = tmpDir.join("test-data.txt")
            try localFS.write(testDataPath, contents: ByteString("best-data"))

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.empty", value: [])
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.empty") == [])

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.binary", value: [0x01, 0x02, 0x03])
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.binary") == [0x01, 0x02, 0x03])

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.binary", value: [0x00, 0x01, 0x02, 0x03])
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.binary") == [0x00, 0x01, 0x02, 0x03])

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.string", value: "true")
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.string") == "true")

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.string", value: "true\0")
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.string") == "true\0")
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.string") != "true")

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.string", value: "tr\0ue\0")
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.string") == "tr\0ue\0")
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.string") != "tr\0ue")

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.string", value: "tr\0ue")
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.string") == "tr\0ue")

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.binaryString", value: [0x00, 0x01, 0x02, 0x03])
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.binaryString") == "\u{0}\u{1}\u{2}\u{3}")

            try localFS.setExtendedAttribute(testDataPath, key: "user.attr.binaryString", value: "\u{0}\u{1}\u{2}\u{3}")
            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.binaryString") == [0x00, 0x01, 0x02, 0x03])

            if try ProcessInfo.processInfo.hostOperatingSystem() == .macOS {
                // Test that the growth of the default-sized 4kb buffer in getExtendedAttribute is covered and works. This is macOS-specific behavior. For the record, on Linux, "ext2/3/4 and btrfs impose much smaller limits, requiring all the attributes (names and values) of one file to fit in one "filesystem block" (usually 4 KiB)".
                let largeData = ByteString([UInt8](repeating: 0xff, count: 8193))
                try localFS.setExtendedAttribute(testDataPath, key: "user.attr.large", value: largeData)
                #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.large") == largeData)

                // Attribute name is too long
                // On Linux, lgetxattr keeps returning ERANGE when the name is out of range, leading to infinite allocation attempt, not sure about the best way to handle this.
                #expect {
                    try localFS.getExtendedAttribute(testDataPath, key: String(repeating: "hello", count: 100))
                } throws: { error in
                    error as? SWBUtil.POSIXError == POSIXError(ENAMETOOLONG, context: "getxattr", testDataPath.str, String(repeating: "hello", count: 100))
                }
            }

            #expect(try localFS.getExtendedAttribute(testDataPath, key: "user.attr.missing") == nil)
        }
    }

    // MARK: PseudoFS Tests

    @Test
    func pseudoBasics() throws {
        let fs = PseudoFS()

        // exists()
        #expect(!fs.exists(Path.root.join("does-not-exist")))
        #expect(fs.exists(.root))

        // isDirectory()
        #expect(!fs.isDirectory(Path.root.join("does-not-exist")))
        #expect(fs.isDirectory(.root))

        // createDirectory()
        #expect(!fs.isDirectory(Path.root.join("new-dir")))
        try fs.createDirectory(Path.root.join("new-dir/subdir"), recursive: true)
        #expect(fs.isDirectory(Path.root.join("new-dir")))
        #expect(fs.isDirectory(Path.root.join("new-dir/subdir")))
    }

    @Test
    func pseudoCreateDirectory() throws {
        let fs = PseudoFS()
        let subdir = Path.root.join("new-dir/subdir")
        try fs.createDirectory(subdir, recursive: true)
        #expect(fs.isDirectory(subdir))

        // Check duplicate creation.
        try fs.createDirectory(subdir, recursive: true)
        #expect(fs.isDirectory(subdir))

        // Check non-recursive subdir creation.
        let subsubdir = subdir.join("new-subdir")
        #expect(!fs.isDirectory(subsubdir))
        try fs.createDirectory(subsubdir, recursive: false)
        #expect(fs.isDirectory(subsubdir))

        // Check non-recursive failing subdir case.
        let newsubdir = Path.root.join("very-new-dir/subdir")
        #expect(!fs.isDirectory(newsubdir))
        #expect(throws: (any Error).self) {
            try fs.createDirectory(newsubdir, recursive: false)
        }
        #expect(!fs.isDirectory(newsubdir))

        // Check directory creation over a file.
        let filePath = Path.root.join("mach_kernel")
        try fs.write(filePath, contents: [0xCD, 0x0D])
        #expect(fs.exists(filePath) && !fs.isDirectory(filePath))
        #expect(throws: (any Error).self) {
            try fs.createDirectory(filePath, recursive: true)
        }
        #expect(throws: (any Error).self) {
            try fs.createDirectory(filePath.join("not-possible"), recursive: true)
        }
        #expect(fs.exists(filePath) && !fs.isDirectory(filePath))
    }

    @Test
    func pseudoCopyFile() throws {
        try _testCopyFile(PseudoFS(), basePath: Path.root.join("new-dir/subdir"))
    }

    @Test
    func pseudoCopyTree() throws {
        try _testCopyTree(PseudoFS(), basePath: Path.root.join("new-dir/subdir"))
    }

    @Test
    func pseudoReadWriteFile() throws {
        let fs = PseudoFS()
        try fs.createDirectory(Path.root.join("new-dir/subdir"), recursive: true)

        let filePath = Path.root.join("new-dir/subdir").join("new-file.txt")
        #expect(!fs.exists(filePath))
        try fs.write(filePath, contents: "Hello, world!")
        #expect(fs.exists(filePath))
        #expect(!fs.isDirectory(filePath))
        #expect(try fs.read(filePath) == "Hello, world!")

        // Check overwrite of a file.
        try fs.write(filePath, contents: "Hello, new world!")
        #expect(try fs.read(filePath) == "Hello, new world!")

        // Check overwrite of a directory (this is an error)
        #expect(throws: (any Error).self) {
            try fs.write(filePath.dirname, contents: [])
        }
        #expect(try fs.read(filePath) == "Hello, new world!")

        // Check write against root (should be an error).
        #expect(throws: (any Error).self) {
            try fs.write(.root, contents: [])
        }
        #expect(fs.exists(filePath))

        // Check write into a non-directory.
        #expect(throws: (any Error).self) {
            try fs.write(filePath.join("not-possible"), contents: [])
        }
        #expect(fs.exists(filePath))

        // Check write into a missing directory.
        let missingDir = Path.root.join("does/not/exist")
        #expect(throws: (any Error).self) {
            try fs.write(missingDir, contents: [])
        }
        #expect(!fs.exists(missingDir))

        // Check attempting to read a directory.
        #expect(throws: (any Error).self) {
            try fs.read(.root)
        }

        // Check attempting to read a missing path.
        #expect(throws: (any Error).self) {
            try fs.read(missingDir)
        }

        // Check attempting to read *through* a file.
        #expect(throws: (any Error).self) {
            try fs.read(filePath.join("not-possible"))
        }
    }

    @Test
    func pseudoAppendFile() throws {
        let fs = PseudoFS()
        try fs.createDirectory(Path.root.join("new-dir/subdir"), recursive: true)

        // Check appending data to a non-existing file.
        let filePath = Path.root.join("new-dir/subdir").join("new-file.txt")
        #expect(!fs.exists(filePath))
        try fs.append(filePath, contents: "Hello, world!")
        #expect(fs.exists(filePath))
        #expect(!fs.isDirectory(filePath))
        #expect(try fs.read(filePath) == "Hello, world!")

        // Check appending data to existing file.
        try fs.append(filePath, contents: "Hello, world!")
        #expect(fs.exists(filePath))
        #expect(!fs.isDirectory(filePath))
        #expect(try fs.read(filePath) == "Hello, world!Hello, world!")
    }

    @Test
    func pseudoRemoveFile() throws {
        let fs = PseudoFS()
        try fs.createDirectory(Path.root.join("new-dir/subdir"), recursive: true)

        let filePath = Path.root.join("new-dir/subdir").join("new-file.txt")
        #expect(!fs.exists(filePath))
        try fs.write(filePath, contents: "Hello, world!")
        #expect(fs.exists(filePath))
        #expect(!fs.isDirectory(filePath))

        // Now remove the file.
        try fs.remove(filePath)
        #expect(!fs.exists(filePath))
    }

    @Test
    func pseudoSetPermissions() throws {
        let fs = PseudoFS()

        // Test default permissions.
        #expect(try fs.getFilePermissions(.root) == 0o755)
        let filePath = Path.root.join("file.txt")
        try fs.write(filePath, contents: [])
        #expect(try fs.getFilePermissions(filePath) == 0o644)

        // Test setting file permissions.
        let execPath = Path.root.join("script.sh")
        try fs.write(execPath, contents: [])
        #expect(try fs.getFilePermissions(execPath) == 0o644)
        try fs.setFilePermissions(execPath, permissions: 0o755)
        #expect(try fs.getFilePermissions(execPath) == 0o755)
    }

    @Test
    func pseudoTraverse() throws {
        let fs = PseudoFS()

        let tmpDir = Path.root

        let p0 = tmpDir.join("a")
        try fs.write(p0, contents: [])

        let p1 = tmpDir.join("b")
        try fs.createDirectory(p1)

        let p2 = p1.join("c")
        try fs.write(p2, contents: [])

        var seen: [Path] = []
        try fs.traverse(tmpDir) {
            seen.append($0)
        }

        // One visit for each path
        #expect(seen.count == Set(seen).count)

        // Order doesn't matter
        #expect(Set(seen) == Set([p0, p1, p2]))
    }

    @Test
    func pseudoGetFileInfo() throws {
        let fs = PseudoFS()

        // Create some example content.
        try fs.createDirectory(Path.root.join("subdir"), recursive: true)
        try fs.write(Path.root.join("subdir/a.txt"), contents: "a")
        try fs.write(Path.root.join("subdir/b.txt"), contents: "b")

        // Check that file stat information differs.
        #expect(try fs.getFileInfo(Path.root.join("subdir/a.txt")) != fs.getFileInfo(Path.root.join("subdir/b.txt")))

#if !os(Windows)
        // Check that we can get stat info on the directory.
        let s = try fs.getFileInfo(Path.root.join("subdir"))
        #expect(s.statBuf.st_mode & S_IFDIR == S_IFDIR)
        #expect(s.statBuf.st_size == 2)

        // Check that the stat info changes if we mutate the directory.
        try fs.remove(Path.root.join("subdir/b.txt"))
        try fs.write(Path.root.join("subdir/c.txt"), contents: "c")
        let s2 = try fs.getFileInfo(Path.root.join("subdir"))
        #expect(s != s2)
#endif
    }

    @Test
    func pseudoMoveInSameVolume() throws {
        func checkMove(_ run: (PseudoFS) throws -> Void) throws {
            let fs = PseudoFS()
            try fs.createDirectory(Path.root.join("dir1"), recursive: true)
            try fs.createDirectory(Path.root.join("dir2"), recursive: true)
            try fs.createDirectory(Path.root.join("dir1/dir3"), recursive: true)
            try fs.write(Path.root.join("a.txt"), contents: "a")
            try fs.setFilePermissions(Path.root.join("a.txt"), permissions: 0o755)
            try fs.write(Path.root.join("b.txt"), contents: "b")
            try fs.write(Path.root.join("dir1/c.txt"), contents: "c")
            try run(fs)
        }

        // Check various errors
        try checkMove { fs in
            #expect(throws: (any Error).self) {
                try fs.moveInSameVolume(.root, to: Path.root.join("dir1/movedroot"))
            }
            #expect(throws: (any Error).self) {
                try fs.moveInSameVolume(Path.root.join("dir1"), to: .root)
            }
            #expect(throws: (any Error).self) {
                try fs.moveInSameVolume(Path.root.join("dir1"), to: Path.root.join("dir2"))
            }
            #expect(throws: (any Error).self) {
                try fs.moveInSameVolume(Path.root.join("dir1"), to: Path.root.join("a.txt"))
            }
            #expect(throws: (any Error).self) {
                try fs.moveInSameVolume(Path.root.join("a.txt"), to: Path.root.join("dir1"))
            }
        }

        // Check moving a file
        try checkMove { fs in
            let fileA = Path.root.join("a.txt")
            let movedA = Path.root.join("dir1/moveda.txt")

            try fs.moveInSameVolume(fileA, to: movedA)

            #expect(!fs.exists(fileA))
            #expect(try fs.read(movedA) == "a")
            #expect(try fs.getFilePermissions(movedA) == 0o755)
        }

        // Check moving a file to an existing file
        try checkMove { fs in
            let fileA = Path.root.join("a.txt")
            let fileB = Path.root.join("b.txt")

            try fs.moveInSameVolume(fileA, to: fileB)

            #expect(!fs.exists(fileA))
            #expect(try fs.read(fileB) == "a")
            #expect(try fs.getFilePermissions(fileB) == 0o755)
        }

        // Check moving a directory
        try checkMove { fs in
            let dir = Path.root.join("dir1")
            let movedDir = Path.root.join("dir2/moveddir")

            try fs.moveInSameVolume(dir, to: movedDir)

            #expect(!fs.exists(dir))
            #expect(fs.isDirectory(movedDir))
            #expect(fs.isDirectory(movedDir.join("dir3")))
            #expect(try fs.read(movedDir.join("c.txt")) == "c")
        }
    }

    @Test
    func pseudoSymlink() throws {
        let fs = PseudoFS()
        let subdir = Path.root.join("new-dir/subdir")
        try fs.createDirectory(subdir, recursive: true)
        let source = Path.root.join("mylink")
        let target = subdir.join("target")
        var destinationExists = false
        #expect(!fs.isSymlink(source, &destinationExists))
        #expect(!destinationExists)

        try fs.symlink(source, target: target)
        #expect(try fs.getFileInfo(source).isSymlink)
        #expect(fs.isSymlink(source, &destinationExists))
        #expect(!destinationExists)
        #expect(try fs.readlink(source) == target)

        try fs.createDirectory(target)
        #expect(fs.isSymlink(source, &destinationExists))
        #expect(destinationExists)
    }

    @Test
    func exists() throws {
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            #expect(try localFS.exists(Path(#require(getEnvironmentVariable("SystemRoot")))))
        } else {
            #expect(localFS.exists(Path.root.join("tmp")))
        }
        #expect(!localFS.exists(Path.root.join("this/path/does/not/exist")))
    }

    @Test
    func isDirectory() throws {
        #expect(localFS.isDirectory(.root))
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            #expect(try localFS.isDirectory(Path(#require(getEnvironmentVariable("SystemRoot")))))
        } else {
            #expect(localFS.isDirectory(Path.root.join("tmp")))
        }
        #expect(!localFS.isDirectory(Path.null))
        #expect(!localFS.isDirectory(Path.root.join("this/path/does/not/exist")))
    }

    @Test
    func isSymlink() throws {
        try withTemporaryDirectory { tmpDir in
            var destinationExists = false

            // Test checking a file that does not exist.
            #expect(!localFS.isSymlink(Path.root.join("this/path/does/not/exist"), &destinationExists))
            #expect(!destinationExists)

            // Create a file that exists and a symlink to it and check that we detect the symlink correctly.
            let dirPath = tmpDir.join("dir")
            try localFS.createDirectory(dirPath, recursive: true)
            let filePath = dirPath.join("file")
            let symlinkPath = tmpDir.join("symlink")
            try localFS.write(filePath, contents: ByteString([]))
            try localFS.symlink(symlinkPath, target: filePath)
            #expect(localFS.isSymlink(symlinkPath, &destinationExists))
            #expect(destinationExists)

            // Test that the file which is not a symlink is detected correctly.  Also test a directory.
            #expect(!localFS.isSymlink(filePath, &destinationExists))
            #expect(!destinationExists)
            #expect(!localFS.isSymlink(dirPath, &destinationExists))
            #expect(!destinationExists)

            // Create a symlink to a file that does not exist and check that we detect that.
            let badSymlinkPath = tmpDir.join("bad")
            try localFS.symlink(badSymlinkPath, target: Path.root.join("this/path/does/not/exist"))
            #expect(localFS.isSymlink(badSymlinkPath, &destinationExists))
            #expect(!destinationExists)
        }
    }

    // MARK: File Signature Tests

    @Test
    func emptyFilesSignature() throws {
        let fs = PseudoFS()

        let signature = fs.filesSignature([Path]())
        let otherSignature = fs.filesSignature([Path]())
        #expect(signature == otherSignature)
    }

    @Test
    func flatFilesSignature() throws {
        let fs = localFS

        try withTemporaryDirectory { tmpDir in
            let file0 = tmpDir.join("file0")
            try fs.write(file0, contents: ByteString("file0"))
            let sig0a = fs.filesSignature([file0])
            let sig0b = fs.filesSignature([file0])
            #expect(sig0a == sig0b)

            let file1 = tmpDir.join("file1")
            try fs.write(file1, contents: ByteString("file1"))
            let sig1a = fs.filesSignature([file1])
            #expect(sig0a != sig1a)

            try fs.setFileTimestamp(file1, timestamp: fs.getFileTimestamp(file1) + 1)
            let sig1b = fs.filesSignature([file1])
            #expect(sig1a != sig1b)

            // If a file does not exist, we need to note that in the signature, we can't just ignore it
            let file2 = tmpDir.join("file2")
            #expect(!fs.exists(file2))
            #expect(fs.filesSignature([file1]) != fs.filesSignature([file1, file2]))
        }
    }

    @Test
    func fileSignatureHonorIgnoreDeviceInodeChangesSettingPseudoFS() throws {
        try _testFileSignatureHonorIgnoreDeviceInodeChangesSetting(simulated: true, at: Path.root.join("base"))
    }

    @Test(.requireHostOS(.macOS)) // copying the file doesn't guarantee a new inode on Windows or Linux
    func fileSignatureHonorIgnoreDeviceInodeChangesSettingLocalFS() throws {
        try withTemporaryDirectory { tmpDir in
            try _testFileSignatureHonorIgnoreDeviceInodeChangesSetting(simulated: false, at: tmpDir)
        }
    }

    @Test
    func treeFilesSignature() throws {
        let fs = localFS

        try withTemporaryDirectory { tmpDir in
            let dir0 = tmpDir.join("dir0")
            try fs.createDirectory(dir0)

            let dir1 = dir0.join("dir1")
            try fs.createDirectory(dir1)

            let file0 = dir1.join("file0")
            try fs.write(file0, contents: ByteString("file0"))

            let sigDir0a = fs.filesSignature([dir0])
            let sigDir0b = fs.filesSignature([dir0])
            #expect(sigDir0a == sigDir0b)

            let sigDir1 = fs.filesSignature([dir1])
            #expect(sigDir0a != sigDir1)

            let sigFile0a = fs.filesSignature([file0])
            #expect(sigDir0a != sigFile0a)

            try fs.setFileTimestamp(file0, timestamp: fs.getFileTimestamp(file0) + 1)
            let sigFile0b = fs.filesSignature([file0])
            #expect(sigFile0a != sigFile0b)

            let sigDir0c = fs.filesSignature([dir0])
            #expect(sigDir0b != sigDir0c)
        }
    }

    @Test
    func treeFilesSignatureHonorIgnoreDeviceInodeChangesSettingPseudoFS() throws {
        try _testTreeFilesSignatureHonorIgnoreDeviceInodeChangesSetting(simulated: true, at: Path.root.join("some/path"))
    }

    @Test(.requireHostOS(.macOS))
    func treeFilesSignatureHonorIgnoreDeviceInodeChangesSettingLocalFS() throws {
        try withTemporaryDirectory { tmpDir in
            try _testTreeFilesSignatureHonorIgnoreDeviceInodeChangesSetting(simulated: false, at: tmpDir)
        }
    }

    @Test
    func pseudoRemoveDirectory() {
        let fs = PseudoFS()
        removeFileTreeTester(fs: fs, basePath: Path.root.join("tmp"))
    }

    // MARK: Shared File System Test Implementations

    func _testCopyFile(_ fs: any FSProxy, basePath: Path) throws {
        let subdir = basePath.join("src-dir")
        try fs.createDirectory(subdir, recursive: true)

        let testData = (0..<1000).map { $0.description }.joined(separator: ", ")
        let testDataPath = subdir.join("test-data.txt")
        let testDataPathDst = subdir.join("test-data-2.txt")
        let permissions: Int = 0o755

        try fs.write(testDataPath, contents: ByteString(testData))
        try fs.setFilePermissions(testDataPath, permissions: permissions)

        try fs.copy(testDataPath, to: testDataPathDst)

        #expect(fs.exists(testDataPath))
        // POSIX permissions model is inapplicable to Windows
        if try ProcessInfo.processInfo.hostOperatingSystem() != .windows {
            #expect(try fs.getFilePermissions(testDataPathDst) == permissions)
        }
        if fs is PseudoFS {
            // There is no guarantee that the implementation of copy() will preserve the modification timestamp on either files and/or directories, on any real filesystem, so only make this assertion for the pseudo filesystem which we wholly control.
            #expect(try fs.getFileInfo(testDataPath).modificationDate == fs.getFileInfo(testDataPathDst).modificationDate)
        }
        #expect(try ByteString(testData) == fs.read(testDataPathDst))
    }

    func _testCopyTree(_ fs: any FSProxy, basePath: Path) throws {
        func compareFileInfo(_ lhs: FileInfo, _ rhs: FileInfo, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(lhs.group == rhs.group, sourceLocation: sourceLocation)
            #expect(lhs.isDirectory == rhs.isDirectory, sourceLocation: sourceLocation)
            #expect(lhs.isExecutable == rhs.isExecutable, sourceLocation: sourceLocation)
            #expect(lhs.isSymlink == rhs.isSymlink, sourceLocation: sourceLocation)
            if fs is PseudoFS {
                // There is no guarantee that the implementation of copy() will preserve the modification timestamp on either files and/or directories, on any real filesystem, so only make this assertion for the pseudo filesystem which we wholly control.
                #expect(lhs.modificationDate == rhs.modificationDate, sourceLocation: sourceLocation)
            }
            #expect(lhs.owner == rhs.owner, sourceLocation: sourceLocation)
            #expect(lhs.permissions == rhs.permissions, sourceLocation: sourceLocation)
        }

        let subdir = basePath.join("src-dir")
        try fs.createDirectory(subdir, recursive: true)

        // Create the directory layout.
        try fs.createDirectory(subdir.join("dir0/dir0_0"), recursive: true)
        try fs.createDirectory(subdir.join("dir1"), recursive: true)

        // Place some files on disk.
        let data0 = (0..<100).map { $0.description }.joined(separator: ", ")
        let data1 = (0..<100).map { ($0 * 2).description }.joined(separator: ", ")
        let file0Perms: Int = 0o755
        let file1Perms: Int = 0o644

        try fs.write(subdir.join("dir0/file0"), contents: ByteString(data0))
        try fs.write(subdir.join("dir0/dir0_0/file1"), contents: ByteString(data1))
        try fs.setFilePermissions(subdir.join("dir0/file0"), permissions: file0Perms)
        try fs.setFilePermissions(subdir.join("dir0/dir0_0/file1"), permissions: file1Perms)

        // Ensure the file system is what we expected before the copy.
        #expect(fs.exists(subdir.join("dir0/file0")))
        #expect(fs.exists(subdir.join("dir0/dir0_0/file1")))

        // Copy the directory to its new location and verify the copies exist.
        let subdirDst = basePath.join("dst-dir")
        try fs.copy(subdir, to: subdirDst)
        #expect(fs.exists(subdirDst.join("dir0/file0")))
        #expect(fs.exists(subdirDst.join("dir0/dir0_0/file1")))

        // Verify the contents and file/dir attributes.
        // POSIX permissions model is inapplicable to Windows
        if try ProcessInfo.processInfo.hostOperatingSystem() != .windows {
            #expect(try fs.getFilePermissions(subdirDst.join("dir0/file0")) == file0Perms)
            #expect(try fs.getFilePermissions(subdirDst.join("dir0/dir0_0/file1")) == file1Perms)
        }
        compareFileInfo(try fs.getFileInfo(subdirDst.join("dir0")), try fs.getFileInfo(subdir.join("dir0")))
        compareFileInfo(try fs.getFileInfo(subdirDst.join("dir0/file0")), try fs.getFileInfo(subdir.join("dir0/file0")))
        compareFileInfo(try fs.getFileInfo(subdirDst.join("dir0/dir0_0/file1")), try fs.getFileInfo(subdir.join("dir0/dir0_0/file1")))
        compareFileInfo(try fs.getFileInfo(subdirDst.join("dir0/dir0_0")), try fs.getFileInfo(subdir.join("dir0/dir0_0")))
        compareFileInfo(try fs.getFileInfo(subdirDst.join("dir1")), try fs.getFileInfo(subdir.join("dir1")))

        // Test the file contents.
        #expect(try ByteString(data0) == fs.read(subdirDst.join("dir0/file0")))
        #expect(try ByteString(data1) == fs.read(subdirDst.join("dir0/dir0_0/file1")))
    }

    func _testFileSignatureHonorIgnoreDeviceInodeChangesSetting(simulated: Bool, at basePath: Path) throws {
        for shouldIgnoreDeviceInodeChanges in [true, false] {
            let fs = createFS(simulated: simulated, ignoreFileSystemDeviceInodeChanges: shouldIgnoreDeviceInodeChanges)

            try fs.createDirectory(basePath, recursive: true)

            let file0 = basePath.join("file0")
            try fs.write(file0, contents: ByteString("file0"))

            // The original signature. This needs to be based on the status of the user default.
            let sig0a_orig = fs.filesSignature([file0])

            // Validate that the inode/device info is only 0 when the info should be ignored.
            let inode = try fs.getFileInfo(file0).statBuf.st_ino
            #expect((inode == 0) == shouldIgnoreDeviceInodeChanges)
            let device = try fs.getFileInfo(file0).statBuf.st_dev
            #expect((device == 0) == shouldIgnoreDeviceInodeChanges)

            // Copy the file and copy it back, keeping the attributes of the file intact. NOTE!! Do not change this from copy/remove to move as that will **not** necessarily change the st_ino value. By copying the file, we can guarantee that a new file inode must be created.
            let file0_copy = basePath.join("file0_copy")
            try fs.copy(file0, to: file0_copy)
            try fs.remove(file0)
            #expect(!fs.exists(file0))
            #expect(fs.exists(file0_copy))

            try fs.copy(file0_copy, to: file0)
            try fs.remove(file0_copy)
            #expect(fs.exists(file0))
            #expect(!fs.exists(file0_copy))

            // The signatures should match **only** if the inode and device information are being 0'd out.
            let sig0a_copy = fs.filesSignature([file0])
            #expect((sig0a_orig == sig0a_copy) == shouldIgnoreDeviceInodeChanges)
        }
    }

    func _testTreeFilesSignatureHonorIgnoreDeviceInodeChangesSetting(simulated: Bool, at basePath: Path) throws {
        for shouldIgnoreDeviceInodeChanges in [true, false] {
            let fs = createFS(simulated: simulated, ignoreFileSystemDeviceInodeChanges: shouldIgnoreDeviceInodeChanges)

            let dir0 = basePath.join("dir0")
            try fs.createDirectory(dir0, recursive: true)

            let dir1 = dir0.join("dir1")
            try fs.createDirectory(dir1)

            let file0 = dir1.join("file0")
            try fs.write(file0, contents: ByteString("file0"))

            // The original signature. This needs to be based on the status of the user default.
            let sigDir0_orig = fs.filesSignature([dir0])
            let sigDir1_orig = fs.filesSignature([dir1])
            let sigFile0_orig = fs.filesSignature([file0])

            // Validate that the inode/device info is only 0 when the info should be ignored.
            for file in [dir0, dir1, file0] {
                let inode = try fs.getFileInfo(file).statBuf.st_ino
                #expect((inode == 0) == shouldIgnoreDeviceInodeChanges)
                let device = try fs.getFileInfo(file).statBuf.st_dev
                #expect((device == 0) == shouldIgnoreDeviceInodeChanges)
            }

            // Copy the file and copy it back, keeping the attributes of the file intact. NOTE!! Do not change this from copy/remove to move as that will **not** necessarily change the st_ino value. By copying the file, we can guarantee that a new file inode must be created.
            let dir0_copy = basePath.join("dir0_copy")
            try fs.copy(dir0, to: dir0_copy)
            try fs.removeDirectory(dir0)
            #expect(!fs.exists(dir0))
            #expect(fs.exists(dir0_copy))

            try fs.copy(dir0_copy, to: dir0)
            try fs.removeDirectory(dir0_copy)
            #expect(fs.exists(dir0))
            #expect(!fs.exists(dir0_copy))

            // The signatures should match **only** if the inode and device information are being 0'd out.
            let sigDir0_copy = fs.filesSignature([dir0])
            let sigDir1_copy = fs.filesSignature([dir1])
            let sigFile0_copy = fs.filesSignature([file0])
            #expect((sigDir0_orig == sigDir0_copy) == shouldIgnoreDeviceInodeChanges)
            #expect((sigDir1_orig == sigDir1_copy) == shouldIgnoreDeviceInodeChanges)
            #expect((sigFile0_orig == sigFile0_copy) == shouldIgnoreDeviceInodeChanges)
        }
    }

    @Test
    func writeIfChanged() throws {
        let fs = localFS
        try withTemporaryDirectory(fs: fs) { dir throws in
            // Should succeed if no existing file
            #expect(try fs.writeIfChanged(dir.join("foo"), contents: ""))

            // Same content should do nothing
            #expect(try !fs.writeIfChanged(dir.join("foo"), contents: ""))

            // Different content should write it out
            #expect(try fs.writeIfChanged(dir.join("foo"), contents: "a"))
            #expect(try fs.read(dir.join("foo")) == ByteString(encodingAsUTF8: "a"))

            // Same again
            #expect(try !fs.writeIfChanged(dir.join("foo"), contents: "a"))
            #expect(try fs.read(dir.join("foo")) == ByteString(encodingAsUTF8: "a"))
        }
    }
}

/// Helper method to test file tree removal method on the given file system.
///
/// - Parameters:
///   - fs: The filesystem to test on.
///   - basePath: The path at which the temporary file structure should be created.
private func removeFileTreeTester(fs: any FSProxy, basePath path: Path, sourceLocation: SourceLocation = #_sourceLocation) {
    // Test removing folders.
    let folders = path.join("foo/bar/baz")
    try? fs.createDirectory(folders, recursive: true)
    #expect(fs.exists(folders), sourceLocation: sourceLocation)
    try? fs.removeDirectory(folders)
    #expect(!fs.exists(folders), sourceLocation: sourceLocation)

    // Test removing file.
    let filePath = folders.join("foo.txt")
    try? fs.createDirectory(folders, recursive: true)
    try? fs.write(filePath, contents: "foo")
    #expect(fs.exists(filePath), sourceLocation: sourceLocation)
    try? fs.removeDirectory(folders)
    #expect(!fs.exists(filePath), sourceLocation: sourceLocation)
}
