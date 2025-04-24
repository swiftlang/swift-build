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
import SWBUtil
import SWBTestSupport
import SWBCore

#if canImport(System)
import System
#else
import SystemPackage
#endif

@Suite
fileprivate struct PBXCpTests: CoreBasedTests {
    @Test
    func usage() async {
        let result = await pbxcp(["builtin-copy", "--help"], cwd: Path("/"))
        #expect(result.success == false)
        XCTAssertMatch(result.output, .contains("USAGE: builtin-copy [<options>] <paths> ..."))
    }

    @Test
    func usageParallel() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await self.exclude()
                }
            }
            try await group.waitForAll()
        }
    }

    /// Test the `-exclude` option, which is a file pattern which will not be copied to the destination..
    @Test
    func exclude() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let fs = localFS

            try fs.createDirectory(src)
            // The destination has to exist, I guess?
            try fs.write(src.join("a"), contents: "A")
            try fs.write(src.join("exclude"), contents: "exclude")
            try fs.createDirectory(src.join("subdir"))
            try fs.write(src.join("subdir").join("exclude"), contents: "")
            try fs.write(src.join("subdir").join("nonexclude"), contents: "")
            try fs.write(src.join("subdir").join("excluded_by_pattern"), contents: "")

            // Test a single exclude pattern.
            do {
                let dst = tmp.join("dst1")
                let result = await pbxcp(["builtin-copy", "-exclude", "exclude*", "-v", src.str + Path.pathSeparatorString, src.join("exclude").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying src/...\n" +
                    "copying exclude...\n" +
                    " 7 bytes\n"))
                #expect(try fs.listdir(dst).sorted() == ["a", "exclude", "subdir"])
                #expect(try fs.listdir(dst.join("subdir")).sorted() == ["nonexclude"])
                #expect(try fs.read(dst.join("a")) == "A")
            }

            // Test multiple exclude patterns.
            do {
                let dst = tmp.join("dst2")
                let result = await pbxcp(["builtin-copy", "-exclude", "exclude*", "-exclude", "nonexclude", "-v", src.str + Path.pathSeparatorString, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == "copying src/...\n")
                #expect(try fs.listdir(dst).sorted() == ["a", "subdir"])
                #expect(try fs.listdir(dst.join("subdir")).sorted() == [])
                #expect(try fs.read(dst.join("a")) == "A")
            }
        }
    }

    /// Test the `-exclude_subpath`  option.
    @Test
    func excludeSubpath() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let fs = localFS

            try fs.createDirectory(src)
            try fs.createDirectory(src.join("Any.framework"))
            try fs.write(src.join("Any.framework").join("Any"), contents: "Anything")
            try fs.createDirectory(src.join("Any.framework").join("Many"))
            try fs.write(src.join("Any.framework").join("Many").join("A"), contents: "A")
            try fs.write(src.join("Any.framework").join("Many").join("B"), contents: "B")
            try fs.createDirectory(src.join("Any.framework").join("Resources"))
            try fs.write(src.join("Any.framework").join("Resources").join("A"), contents: "A")
            try fs.write(src.join("Any.framework").join("Resources").join("B"), contents: "B")

            do {
                let dst = tmp.join("dst1")
                // The destination has to exist, I guess?
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-exclude_subpath", "Any", "-v", src.join("Any.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Any.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Any.framework"])
                #expect(try fs.listdir(dst.join("Any.framework")).sorted() == ["Many", "Resources"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Resources")).sorted() == ["A", "B"])
            }

            do {
                let dst = tmp.join("dst2")
                // The destination has to exist, I guess?
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-exclude_subpath", "Resources", "-v", src.join("Any.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Any.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Any.framework"])
                #expect(try fs.listdir(dst.join("Any.framework")).sorted() == ["Any", "Many"])
            }

            do {
                let dst = tmp.join("dst3")
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-exclude_subpath", "Resources/A", "-v", src.join("Any.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Any.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Any.framework"])
                #expect(try fs.listdir(dst.join("Any.framework")).sorted() == ["Any", "Many", "Resources"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Resources")).sorted() == ["B"])
            }

            do {
                let dst = tmp.join("dst4")
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-exclude_subpath", "Resources/A", "-exclude_subpath", "Many", "-v", src.join("Any.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Any.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Any.framework"])
                #expect(try fs.listdir(dst.join("Any.framework")).sorted() == ["Any", "Resources"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Resources")).sorted() == ["B"])
            }
        }
    }



    /// Test the `-resolve-src-symlink` option.
    @Test
    func symlinkedFileWithResolvedSym() async throws {
        try await withTemporaryDirectory { tmp in
            let fs = localFS

            // Copy the resolved file but with the original src name.
            do {
                // Create a macOS-style framework bundle so we can test copying symlinks.
                let src = tmp.join("src1")
                try fs.createDirectory(src)
                let dir = src.join("dir")
                try fs.createDirectory(dir)
                try fs.write(src.join("File"), contents: "Anything")
                try fs.symlink(dir.join("SymLinked"), target: Path("../File"))

                let dst = tmp.join("dst1")
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-v", "-resolve-src-symlinks", dir.join("SymLinked").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(fs.exists(dst.join("SymLinked")))
                #expect(try fs.read(dst.join("SymLinked")) == "Anything")
                #expect(result.output == (
                    "copying File...\n 8 bytes\n"))
            }

            do {
                let src = tmp.join("src2")
                try fs.createDirectory(src)
                let dir = src.join("dir")
                try fs.createDirectory(dir)
                try fs.write(dir.join("File"), contents: "Anything")
                try fs.symlink(dir.join("SymLinked"), target: Path("File"))

                let dst = tmp.join("dst2")
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-v", "-resolve-src-symlinks", dir.join("SymLinked").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(fs.exists(dst.join("SymLinked")))
                #expect(try fs.read(dst.join("SymLinked")) == "Anything")
                #expect(result.output == (
                    "copying File...\n 8 bytes\n"))
            }
        }
    }

    /// Test the `-include_only_subpath` option.
    @Test
    func includeOnlySubpath() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let fs = localFS

            // Create a macOS-style framework bundle so we can test copying symlinks.
            try fs.createDirectory(src)
            try fs.createDirectory(src.join("Any.framework"))
            try fs.createDirectory(src.join("Any.framework").join("Versions"))
            try fs.createDirectory(src.join("Any.framework").join("Versions").join("A"))
            try fs.symlink(src.join("Any.framework").join("Versions").join("Current"), target: Path("A"))
            try fs.write(src.join("Any.framework").join("Versions").join("A").join("Any"), contents: "Anything")
            try fs.symlink(src.join("Any.framework").join("Any"), target: Path("Versions").join("Current").join("Any"))
            try fs.createDirectory(src.join("Any.framework").join("Versions").join("A").join("_CodeSignature"))
            try fs.write(src.join("Any.framework").join("Versions").join("A").join("_CodeSignature").join("CodeResources"), contents: "Signing Resources")
            try fs.createDirectory(src.join("Any.framework").join("Versions").join("A").join("Resources"))
            try fs.symlink(src.join("Any.framework").join("Resources"), target: Path("Versions").join("Current"))
            try fs.write(src.join("Any.framework").join("Versions").join("A").join("Resources").join("A"), contents: "A")
            try fs.write(src.join("Any.framework").join("Versions").join("A").join("Resources").join("B"), contents: "B")

            // Simplest test copies only the binary.
            do {
                let dst = tmp.join("dst1")
                // The destination has to exist, I guess?
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-include_only_subpath", "Versions/A/Any", "-v", src.join("Any.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Any.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Any.framework"])
                #expect(try fs.listdir(dst.join("Any.framework")).sorted() == ["Versions"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions")).sorted() == ["A"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions").join("A")).sorted() == ["Any"])
            }

            // Next test copies the binary and the _CodeSignature directory, which should also include the contents of that directory.
            do {
                let dst = tmp.join("dst2")
                // The destination has to exist, I guess?
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-include_only_subpath", "Versions/A/Any", "-include_only_subpath", "Versions/A/_CodeSignature", "-v", src.join("Any.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Any.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Any.framework"])
                #expect(try fs.listdir(dst.join("Any.framework")).sorted() == ["Versions"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions")).sorted() == ["A"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions").join("A")).sorted() == ["Any", "_CodeSignature"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions").join("A").join("_CodeSignature")).sorted() == ["CodeResources"])
            }

            // Next test copies the binary, _CodeSignature directory, and symlinks
            do {
                let dst = tmp.join("dst3")
                // The destination has to exist, I guess?
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-include_only_subpath", "Versions/A/Any", "-include_only_subpath", "Versions/A/_CodeSignature", "-include_only_subpath", "Any", "-include_only_subpath", "Versions/Current", "-v", src.join("Any.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Any.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Any.framework"])
                #expect(try fs.listdir(dst.join("Any.framework")).sorted() == ["Any", "Versions"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions")).sorted() == ["A", "Current"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions").join("A")).sorted() == ["Any", "_CodeSignature"])
                #expect(try fs.listdir(dst.join("Any.framework").join("Versions").join("A").join("_CodeSignature")).sorted() == ["CodeResources"])
            }

            // Create an iOS-style framework bundle so we can test copying (or not copying) things at the same level as the binary.
            try fs.createDirectory(src.join("Again.framework"))
            try fs.write(src.join("Again.framework").join("Again"), contents: "Something")
            try fs.write(src.join("Again.framework").join("Again.car"), contents: "Assets")         // Should not be copied
            try fs.createDirectory(src.join("Again.framework").join("_CodeSignature"))
            try fs.write(src.join("Again.framework").join("_CodeSignature").join("CodeResources"), contents: "Signing Resources")
            try fs.createDirectory(src.join("Again.framework").join("Resources"))
            try fs.write(src.join("Again.framework").join("Resources").join("A"), contents: "A")
            try fs.write(src.join("Again.framework").join("Resources").join("B"), contents: "B")

            // Copy the binary and the _CodeSignature directory, which should also include the contents of that directory.
            do {
                let dst = tmp.join("dst4")
                // The destination has to exist, I guess?
                try fs.createDirectory(dst)
                let result = await pbxcp(["builtin-copy", "-include_only_subpath", "Again", "-include_only_subpath", "_CodeSignature", "-v", src.join("Again.framework").str, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying Again.framework/...\n"))
                #expect(try fs.listdir(dst).sorted() == ["Again.framework"])
                #expect(try fs.listdir(dst.join("Again.framework")).sorted() == ["Again", "_CodeSignature"])
                #expect(try fs.listdir(dst.join("Again.framework").join("_CodeSignature")).sorted() == ["CodeResources"])
            }
        }
    }

    /// Check that we can invoke `strip`.
    @Test 
    func stripUnstrippedBinaries() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let dst = tmp.join("dst")
            let fs = localFS

            try fs.createDirectory(src)
            // The destination has to exist, I guess?
            try fs.createDirectory(dst)
            // This is a fake Mach-O file, just enough to trick PBXCp.
            try fs.write(src.join("fake-bin"), contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])
            // And also add a plain text file to make sure it doesn't get stripped.
            try fs.write(src.join("txt"), contents: "text file")

            do {
                // Check that we run the strip tool and capture its output.
                let result = await pbxcp(["builtin-copy", "-dry-run", "-strip-tool", "echo", "-strip-unsigned-binaries", "-v", src.str + Path.pathSeparatorString, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying src/...\n" +
                    "echo -S -no_atom_info \(src.join("fake-bin").str) -o \(dst.join("fake-bin").str)\n"))
            }
        }
    }

     @Test 
    func relativeDestinationToCWD() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let dst = tmp.join("dst")
            let fs = localFS

            try fs.createDirectory(src)
            // This is a fake Mach-O file, just enough to trick PBXCp.
            try fs.write(src.join("fake-bin"), contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])
            // And also add a plain text file to make sure it doesn't get stripped.
            try fs.write(src.join("txt"), contents: "text file")

            do {
                // Check that we run the strip tool and capture its output.
                let result = await pbxcp(["builtin-copy", "-dry-run", "-strip-tool", "echo", "-strip-unsigned-binaries", "-v", src.str + Path.pathSeparatorString, ""], cwd: dst)
                #expect(result.success == true)
                #expect(result.output == (
                    "copying src/...\n" +
                    "echo -S -no_atom_info \(src.join("fake-bin").str) -o \(dst.join("fake-bin").str)\n"))
            }

            do {
                // Check that we run the strip tool and capture its output.
                let result = await pbxcp(["builtin-copy", "-dry-run", "-strip-tool", "echo", "-strip-unsigned-binaries", "-v", src.str + Path.pathSeparatorString, ""], cwd: dst)
                #expect(result.success == true)
                #expect(result.output == (
                    "copying src/...\n" +
                    "echo -S -no_atom_info \(src.join("fake-bin").str) -o \(dst.join("fake-bin").str)\n"))
            }
        }
    }


    /// Check that we can invoke `strip` to copy a specific subopath and nothing else.
    @Test
    func stripSubpath() async throws {
        try await withTemporaryDirectory { tmp in
            // Test stripping specific subpaths in a framework.
            let src = tmp.join("src")
            let fwkName = "fwk.framework"
            let fwk = src.join(fwkName)
            let dst = tmp.join("dst")
            let fs = localFS

            try fs.createDirectory(fwk, recursive: true)
            // The destination has to exist, I guess?
            try fs.createDirectory(dst)
            // This is a fake Mach-O file, just enough to trick PBXCp.
            try fs.write(fwk.join("fwk"), contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])
            try fs.write(fwk.join("bogus"), contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])

            // Check that we run the strip tool and capture its output. We expect to strip 'fwk' but not 'bogus'.
            do {
                let result = await pbxcp(["builtin-copy", "-dry-run", "-strip-tool", "echo", "-strip_subpath", "\(fwkName)/fwk", "-v", fwk.str + Path.pathSeparatorString, dst.join(fwkName).str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying \(fwkName)/...\n" +
                    "echo -S -no_atom_info \(fwk.join("fwk").str) -o \(dst.join(fwkName).join("fwk").str)\n"                ))
            }

            // Test stripping a standalone binary.
            let binaryName = "binary"
            let bin = src.join(binaryName)
            // This is a fake Mach-O file, just enough to trick PBXCp.
            try fs.write(bin, contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])

            // Check that we run the strip tool and capture its output.
            do {
                let result = await pbxcp(["builtin-copy", "-dry-run", "-strip-tool", "echo", "-strip_subpath", binaryName, "-v", bin.str + Path.pathSeparatorString, dst.join(binaryName).str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying and stripping \(binaryName)...\n" +
                    "echo -S -no_atom_info \(bin.str) -o \(dst.join(binaryName).str)\n" +
                    " 12 bytes\n"
                ))
            }
        }
    }

    /// Test that if we don't pass any stripping options, then no stripping occurs.
    @Test
    func noStrip() async throws {
        try await withTemporaryDirectory { tmp in
            // Test stripping specific subpaths in a framework.
            let src = tmp.join("src")
            let fwkName = "fwk.framework"
            let fName = "fwk"
            let fwk = src.join(fwkName)
            let dst = tmp.join("dst")
            let srcfile = fwk.join(fName)
            let fs = localFS

            try fs.createDirectory(fwk, recursive: true)
            // The destination has to exist, I guess?
            try fs.createDirectory(dst)
            // This is a fake Mach-O file, just enough to trick PBXCp.
            try fs.write(srcfile, contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])
            try fs.setFilePermissions(srcfile, permissions: 0o777)

            // Check that we run the strip tool and capture its output.
            do {
                let result = await pbxcp(["builtin-copy", "-strip-tool", "/bin/echo", "-v", fwk.str + Path.pathSeparatorString, dst.join(fwkName).str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying \(fwkName)/...\n"
                ))
                if try ProcessInfo.processInfo.hostOperatingSystem() != .windows {
                    let dstPerm = try fs.getFilePermissions(dst.join(fwkName).join(fName))
                    #expect(dstPerm == 0o755) // files are created with u+rw, g+wr, o+rw (and +x if src is executable) permissions and umask will adjust
                }
            }
        }
    }

    fileprivate let buffer0 = [UInt8](repeating: 0xAA, count: 1024 * 513)
    fileprivate let buffer1 = [UInt8](repeating: 0x55, count: 1024 * 513)

    @Test(.skipHostOS(.windows, "LocalFS needs to use stat64 on windows...."))
    func largerFile() async throws {
        try await withTemporaryDirectory { tmp in
            // Test copying a large file.
            let src = tmp.join("src")
            let sName = src.join("file")
            let dst = tmp.join("dst")
            let dName = dst.join("file")
            let fs = localFS

            try fs.createDirectory(src, recursive: true)
            var size = 0
            try await fs.write(sName) { fd in
                for _ in 0...4096 {
                    size += try fd.writeAll(buffer0)
                    size += try fd.writeAll(buffer1)
                }
            }
            try fs.setFilePermissions(sName, permissions: 0o600)

            do {
                let result = await pbxcp(["builtin-copy", "-V", src.str + Path.pathSeparatorString, dst.str], cwd: Path("/"))
                #expect(result.success == true)
                #expect(result.output == (
                    "copying src/...\n   copying file...\n    \(size) bytes\n"
                ))
                // Check permissions
                let dstPerm = try fs.getFilePermissions(dName)
                #expect(dstPerm == 0o644) // files are created with u+rw, g+wr, o+rw (and +x if src is executable) permissions and umask will adjust
                #expect(FileManager.default.contentsEqual(atPath: sName.str, andPath: dName.str))
            }
        }
    }


    /// Check that we can invoke `bitcode_strip`.
    @Test
    func bitcodeStrip() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let dst = tmp.join("dst")
            let fs = localFS

            try fs.createDirectory(src)
            // The destination has to exist, I guess?
            try fs.createDirectory(dst)
            // This is a fake Mach-O file, just enough to trick PBXCp.
            try fs.write(src.join("fake-bin"), contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])

            // Check that we run the bitcode_strip tool and capture its output.  Note that bitcode_strip is in the default toolchain, so we need to pass the path to it there.
            let defaultToolchain = try #require(try await getCore().toolchainRegistry.defaultToolchain)
            let bitcodeStripPath = defaultToolchain.path.join("usr/bin/bitcode_strip")
            // Note that we always strip all bitcode (-r), even if 'replace-with-marker' is passed.
            let result = await pbxcp(["builtin-copy", "-dry-run", "-bitcode-strip", "replace-with-marker", "-bitcode-strip-tool", bitcodeStripPath.str, src.str + Path.pathSeparatorString, dst.str], cwd: Path("/"))
            #expect(result.success == true)
            #expect(result.output == (
                bitcodeStripPath.str +
                " \(src.join("fake-bin").str) -r -o \(dst.join("fake-bin").str)\n"))
        }
    }

    @Test
    func bitcodeStripInPlace() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let dst = tmp.join("dst")
            let fs = localFS

            try fs.createDirectory(src)
            // The destination has to exist, I guess?
            try fs.createDirectory(dst)
            // This is a fake Mach-O file, just enough to trick PBXCp.
            try fs.write(src.join("fake-bin"), contents: [0xFE, 0xED, 0xFA, 0xCE, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0])

            // Check that we run the bitcode_strip tool and capture its output.  Note that bitcode_strip is in the default toolchain, so we need to pass the path to it there.
            let defaultToolchain = try #require(try await getCore().toolchainRegistry.defaultToolchain)
            let bitcodeStripPath = defaultToolchain.path.join("usr/bin/bitcode_strip")
            // Note that we always strip all bitcode (-r), even if 'replace-with-marker' is passed.
            let result = await pbxcp(["builtin-copy", "-dry-run", "-strip-unsigned-binaries", "-bitcode-strip", "replace-with-marker", "-bitcode-strip-tool", bitcodeStripPath.str, src.str + Path.pathSeparatorString, dst.str], cwd: Path("/"))
            #expect(result.success == true)
            #expect(result.output.contains(
                bitcodeStripPath.str +
                " \(dst.join("fake-bin").str) -r -o \(dst.join("fake-bin").str)\n"))
        }
    }

    /// Check ignore missing inputs behavior.
    @Test
    func ignoreMissingInputs() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let missingFile = src.join("missingFile")
            let dst = tmp.join("dst")
            let fs = localFS

            try fs.createDirectory(src)
            // The destination has to exist, I guess?
            try fs.createDirectory(dst)

            let failureResult = await pbxcp(["builtin-copy", missingFile.str + Path.pathSeparatorString, dst.str], cwd: Path("/"))
            #expect(failureResult.success == false)
            #expect(failureResult.output == "error: \(missingFile.str): No such file or directory\n")

            let successResult = await pbxcp(["builtin-copy", "-ignore-missing-inputs", missingFile.str + Path.pathSeparatorString, dst.str], cwd: Path("/"))
            #expect(successResult.success == true)
            #expect(successResult.output == (
                "note: ignoring missing input \'\(missingFile.str)\'\n"))
        }
    }

    @Test
    func skipCopyIfContentsEqual() async throws {
        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let dst = tmp.join("dst")
            let fs = localFS
            try fs.write(src, contents: "contents1")

            let result = await pbxcp(["builtin-copy", "-skip-copy-if-contents-equal", "-rename", "-v", src.str, dst.str], cwd: Path("/"))
            #expect(result.success == true)
            #expect(result.output == "copying src...\n 9 bytes\n")
            #expect(try fs.read(dst) == "contents1")

            try await Task.sleep(for: .milliseconds(500))
            let result2 = await pbxcp(["builtin-copy", "-skip-copy-if-contents-equal", "-rename", "-v", src.str, dst.str], cwd: Path("/"))
            #expect(result2.success == true)
            #expect(result2.output == "note: skipping copy of '\(src.str)' because it has the same contents as '\(dst.str)'\n")
            #expect(try fs.read(dst) == "contents1")

            try await Task.sleep(for: .milliseconds(500))
            try fs.write(src, contents: "contents2")
            let result3 = await pbxcp(["builtin-copy", "-skip-copy-if-contents-equal", "-rename", "-v", src.str, dst.str], cwd: Path("/"))
            #expect(result3.success == true)
            #expect(result3.output == "copying src...\n 9 bytes\n")
            #expect(try fs.read(dst) == "contents2")
        }

        try await withTemporaryDirectory { tmp in
            let src = tmp.join("src")
            let dst = tmp.join("dst")
            let srcFile = src.join("file")
            let dstFile = dst.join("file")
            let fs = localFS
            try fs.createDirectory(src)
            try fs.createDirectory(dst)
            try fs.write(srcFile, contents: "contents1")

            let result = await pbxcp(["builtin-copy", "-skip-copy-if-contents-equal", "-v", srcFile.str, dst.str], cwd: Path("/"))
            #expect(result.success == true)
            #expect(result.output == "copying file...\n 9 bytes\n")
            #expect(try fs.read(dstFile) == "contents1")

            try await Task.sleep(for: .milliseconds(500))
            let result2 = await pbxcp(["builtin-copy", "-skip-copy-if-contents-equal", "-rename", "-v", src.str, dst.str], cwd: Path("/"))
            #expect(result2.success == true)
            #expect(result2.output == "note: skipping copy of '\(src.str)' because it has the same contents as '\(dst.str)'\n")
            #expect(try fs.read(dstFile) == "contents1")

            try await Task.sleep(for: .milliseconds(500))
            try fs.write(srcFile, contents: "contents2")
            let result3 = await pbxcp(["builtin-copy", "-skip-copy-if-contents-equal", "-rename", "-v", src.str, dst.str], cwd: Path("/"))
            #expect(result3.success == true)
            #expect(result3.output == "copying src/...\n")
            #expect(try fs.read(dstFile) == "contents2")
        }
    }

    /// Check that we can preserve Finder Info and Resource Forks.
    @Test(.requireHostOS(.macOS))
    func legacyMacOSAttributes() async throws {
        try await withTemporaryDirectory { tmp in
            let srcDir = tmp.join("src")
            let dstDir = tmp.join("dst")
            let fs = localFS

            // Create the source directory, and put in an empty file.
            try fs.createDirectory(srcDir)
            let srcFile = srcDir.join("fndr-and-rsrc")
            try fs.write(srcFile, contents: "abcdef")
#if canImport(Darwin)
            try fs.setExtendedAttribute(srcFile, key: XATTR_FINDERINFO_NAME, value: [
                0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x40, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
            ])
            try fs.setExtendedAttribute(srcFile, key: XATTR_RESOURCEFORK_NAME, value:
                                            "fake"
            )
#endif
            try fs.setExtendedAttribute(srcFile, key: "foo.bar", value:
                                            "should-not-be-copied"
            )

            // Create the empty destination directory.
            try fs.createDirectory(dstDir)

            // Check that copying the file preserves the extended attributes.
            let result = await pbxcp(["builtin-copy", "-preserve-hfs-data", "-v", srcDir.str, dstDir.str], cwd: Path("/"))
            #expect(result.success == true)

            // Examine the files in the output directory.
            let dstFile = dstDir.join(srcDir.basename).join(srcFile.basename)

            // Make sure that the contents were copied.
            #expect(try localFS.read(dstFile) == localFS.read(srcFile))

            // Make sure that the Finder Info and Resource Fork were copied.
#if canImport(Darwin)
            #expect(try localFS.getExtendedAttribute(dstFile, key: XATTR_FINDERINFO_NAME) == localFS.getExtendedAttribute(srcFile, key: XATTR_FINDERINFO_NAME))
            #expect(try localFS.getExtendedAttribute(dstFile, key: XATTR_RESOURCEFORK_NAME) == localFS.getExtendedAttribute(srcFile, key: XATTR_RESOURCEFORK_NAME))
#endif

            // Make sure that arbitrary extended attributes were not copied.
            #expect(try localFS.getExtendedAttribute(dstFile, key: "foo.bar") == nil)
        }
    }

    @Test
    func copyWithDifferentName() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let srcDir = tmpDirPath.join("src")
            let dstDir = tmpDirPath.join("dst")
            let fs = localFS

            // Create the source directory, and put in an empty file.
            try fs.createDirectory(srcDir)
            let srcFile = srcDir.join("original-name")
            try fs.write(srcFile, contents: "abcdef")

            // Create the empty destination directory.
            try fs.createDirectory(dstDir)
            let dstFile = dstDir.join("new-name")

            // Check that copying the file changes its name.
            let result = await pbxcp(["builtin-copy", "-rename", "-v", srcFile.str, dstFile.str], cwd: Path("/"))
            #expect(result.success == true)

            // Make sure that the contents were copied.
            #expect(try localFS.read(dstFile) == localFS.read(srcFile))
        }
    }
}
