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
import SWBTestSupport
@_spi(Testing) import SWBUtil

#if canImport(Darwin)
import MachO

@Suite
fileprivate struct MachOTests {
    let fs = localFS

    func allReaders(_ path: Path, sourceLocation: SourceLocation = #_sourceLocation) throws -> [BinaryReader] {
        return try [
            BinaryReader(data: fs.read(path)),
            BinaryReader(data: #require(FileHandle(forReadingAtPath: path.str), sourceLocation: sourceLocation)),
        ]
    }

    func allReaders(_ contents: ByteString) throws -> [BinaryReader] {
        let tmpDir = try NamedTemporaryDirectory()

        let path = tmpDir.path.join("machO")
        try fs.write(path, contents: contents)
        return try allReaders(path)
    }

    @Test
    func fatMachO() async throws {
        try await testMachO(archs: ["arm64", "x86_64"])
        try await testMachO(archs: ["arm64", "arm64e"])
    }

    @Test
    func thinMachO() async throws {
        try await testMachO(archs: ["x86_64"])
        try await testMachO(archs: ["arm64"])
    }

    func testMachO(archs: [String], platform: BuildVersion.Platform = .macOS, hideARM64: Bool = false) async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            struct Lookup: PlatformInfoLookup {
                func lookupPlatformInfo(platform: BuildVersion.Platform) -> (any PlatformInfoProvider)? {
                    nil
                }
            }

            let machOPath = try await InstalledXcode.currentlySelected().compileExecutable(path: tmpDir, platform: platform, infoLookup: Lookup(), archs: archs, hideARM64: hideARM64)

            if hideARM64 {
                let reader = try BinaryReader(data: fs.read(machOPath))
                let magic: UInt32 = try reader.read()
                let count: UInt32 = try reader.read()
                let presumedArchs = archs.filter({ !$0.hasPrefix("arm64") })
                #expect((magic == FAT_CIGAM || magic == FAT_CIGAM_64 ? count.byteSwapped : count) == UInt32(presumedArchs.count))
            }

            let files: [BinaryReader] = try allReaders(machOPath)

            for file in files {
                let machOReader = BinaryReader(other: file)
                let machO = try MachO(reader: machOReader)
                let (machOSlices, linkage) = try machO.slicesIncludingLinkage()
                #expect(linkage == .macho(.execute))

                func containsArm64(_ arch: String, _ effectiveArchs: [String]) -> Bool {
                    !arch.hasPrefix("arm64") || !effectiveArchs.contains(where: { $0.hasPrefix("arm64") })
                }

                var effectiveArchs: [String] = []
                if hideARM64 {
                    // lipo will hide multiple arm64 slices, but it will only be able to read the first one (us too).
                    // Also, lipo sorts archs.
                    for arch in archs.sorted() {
                        if containsArm64(arch, effectiveArchs) {
                            effectiveArchs.append(arch)
                        }
                    }
                } else {
                    effectiveArchs = archs
                }

                #expect(machOSlices.count == effectiveArchs.count)
                #expect(machOSlices.compactMap { $0.arch }.sorted() == effectiveArchs.sorted())

                let uuids = try Set(machOSlices.compactMap { (slice) -> NSUUID? in
                    if let uuidString = try slice.uuid()?.description {
                        return NSUUID(uuidString: uuidString)
                    }
                    return nil
                })
                #expect(uuids.count == effectiveArchs.count)

                for slice in machOSlices {
                    let libs = try slice.linkedLibraryPaths()
                    #expect(libs == ["/usr/lib/libSystem.B.dylib"])

                    let loadCommands = try slice.loadCommands()
                    #expect(loadCommands.filter { $0.base.cmd == LC_MAIN }.count == 1)
                    #expect(loadCommands.filter { $0.base.cmd == LC_SYMTAB }.count == 1)

                    let _ = try slice.segments()
                    let _ = try slice.segments().map { try $0.sections() }

                    #expect(try slice.swiftABIVersion() == nil)
                }
            }
        }
    }

    @Test
    func fatStaticArchive_MachO() async throws {
        try await testFatStaticArchive_MachO(archs: ["arm64", "arm64e", "x86_64", "x86_64h"])
        try await testFatStaticArchive_MachO(archs: ["x86_64", "x86_64h"])
        try await testFatStaticArchive_MachO(archs: ["arm64", "arm64e"])
    }

    func testFatStaticArchive_MachO(archs: [String]) async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourcePath = tmpDir.join("source.c")
            try fs.write(sourcePath, contents: ByteString("extern int main(){}".data(using: String.Encoding.utf8)!))

            let archs = ["x86_64", "x86_64h"]

            let objectPaths = [tmpDir.join("你好.o"), tmpDir.join("hello.o"), tmpDir.join("path_that_is_longer_than_16_bytes.o")]
            let machOPath = tmpDir.join("machO.a")
            for objectPath in objectPaths {
                _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang"] + archs.flatMap { ["-arch", $0] } + ["-o", objectPath.str, "-c", sourcePath.str])
            }
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "libtool", "-static", "-o", machOPath.str] + objectPaths.map { $0.str })

            let files: [BinaryReader] = try allReaders(machOPath)

            for file in files {
                let machOReader = BinaryReader(other: file)
                let archiveReader = BinaryReader(other: file)

                let machO = try MachO(reader: machOReader)
                let archive = try StaticArchive(reader: archiveReader)

                let machOSlices = try machO.slices()
                let archiveSlices = try archive.machOs().flatMap { try $0.slices() }

                #expect(machOSlices.count == archs.count * objectPaths.count)
                #expect(machOSlices.count == archiveSlices.count)

                let uuids = try Set(machOSlices.compactMap { (slice) -> NSUUID? in
                    if let uuidString = try slice.uuid()?.description {
                        return NSUUID(uuidString: uuidString)
                    }
                    return nil
                })
                #expect(uuids.isEmpty)

                for slice in machOSlices {
                    let libs = try slice.linkedLibraryPaths()
                    #expect(libs.isEmpty)

                    let loadCommands = try slice.loadCommands()
                    #expect(loadCommands.filter { [LC_SEGMENT, LC_SEGMENT_64].contains(Int32($0.base.cmd)) }.count == 1)
                    #expect(loadCommands.filter { $0.base.cmd == LC_SYMTAB }.count == 1)

                    let _ = try slice.segments()
                    let _ = try slice.segments().map { try $0.sections() }

                    #expect(try slice.swiftABIVersion() == nil)
                }
            }
        }
    }

    @Test
    func thinStaticArchive_MachO() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourcePath = tmpDir.join("source.c")
            try fs.write(sourcePath, contents: ByteString("extern int main(){}".data(using: String.Encoding.utf8)!))

            let archs = ["x86_64"]

            let objectPaths = [tmpDir.join("你好.o"), tmpDir.join("hello.o"), tmpDir.join("path_that_is_longer_than_16_bytes.o")]
            let machOPath = tmpDir.join("machO.a")
            for objectPath in objectPaths {
                _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang"] + archs.flatMap { ["-arch", $0] } + ["-o", objectPath.str, "-c", sourcePath.str])
            }
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "libtool", "-static", "-o", machOPath.str] + objectPaths.map { $0.str })

            let files: [BinaryReader] = try allReaders(machOPath)

            for file in files {
                let machOReader = BinaryReader(other: file)
                let archiveReader = BinaryReader(other: file)

                let machO = try MachO(reader: machOReader)
                let archive = try StaticArchive(reader: archiveReader)

                let machOSlices = try machO.slices()
                let archiveSlices = try archive.machOs().flatMap { try $0.slices() }

                #expect(machOSlices.count == archs.count * objectPaths.count)
                #expect(machOSlices.count == archiveSlices.count)

                let uuids = try Set(machOSlices.compactMap { (slice) -> NSUUID? in
                    if let uuidString = try slice.uuid()?.description {
                        return NSUUID(uuidString: uuidString)
                    }
                    return nil
                })
                #expect(uuids.isEmpty)

                for slice in machOSlices {
                    let libs = try slice.linkedLibraryPaths()
                    #expect(libs.isEmpty)

                    let loadCommands = try slice.loadCommands()
                    #expect(loadCommands.filter { [LC_SEGMENT, LC_SEGMENT_64].contains(Int32($0.base.cmd)) }.count == 1)
                    #expect(loadCommands.filter { $0.base.cmd == LC_SYMTAB }.count == 1)

                    let _ = try slice.segments()
                    let _ = try slice.segments().map { try $0.sections() }

                    #expect(try slice.swiftABIVersion() == nil)
                }
            }
        }
    }

    @Test
    func fatStaticArchives() async throws {
        try await testFatStaticArchives(archs: ["arm64", "arm64e", "x86_64", "x86_64h"])
        try await testFatStaticArchives(archs: ["x86_64", "x86_64h"])
        try await testFatStaticArchives(archs: ["arm64", "arm64e"])
    }

    func testFatStaticArchives(archs: [String]) async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourcePath = tmpDir.join("source.c")
            try fs.write(sourcePath, contents: ByteString("extern int main(){}".data(using: String.Encoding.utf8)!))

            let objectPaths = [tmpDir.join("你好.o"), tmpDir.join("hello.o"), tmpDir.join("path_that_is_longer_than_16_bytes.o")]
            let machOPath = tmpDir.join("machO.a")
            for objectPath in objectPaths {
                _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang"] + archs.flatMap { ["-arch", $0] } + ["-o", objectPath.str, "-c", sourcePath.str])
            }
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "libtool", "-static", "-o", machOPath.str] + objectPaths.map { $0.str })

            let files: [BinaryReader] = try allReaders(machOPath)

            for file in files {
                let machO = try MachO(reader: file)
                let linkage = try machO.slicesIncludingLinkage().linkage
                #expect(linkage == .static)

                let archive = try StaticArchive(reader: file)
                #expect(archive.archiveType.isFatArchive)
                let machOs = try archive.machOs()

                #expect(machOs.count == archs.count * objectPaths.count)

                let slices = try machOs.flatMap { try $0.slices() }
                #expect(slices.count == archs.count * objectPaths.count)

                let uuids = try Set(slices.compactMap { (slice) -> NSUUID? in
                    if let uuidString = try slice.uuid()?.description {
                        return NSUUID(uuidString: uuidString)
                    }
                    return nil
                })
                #expect(uuids.isEmpty)

                for machO in machOs {
                    for slice in try machO.slices() {
                        let libs = try slice.linkedLibraryPaths()
                        #expect(libs.isEmpty)

                        let loadCommands = try slice.loadCommands()
                        #expect(loadCommands.filter { [LC_SEGMENT, LC_SEGMENT_64].contains(Int32($0.base.cmd)) }.count == 1)
                        #expect(loadCommands.filter { $0.base.cmd == LC_SYMTAB }.count == 1)

                        let _ = try slice.segments()
                        let _ = try slice.segments().map { try $0.sections() }

                        #expect(try slice.swiftABIVersion() == nil)
                    }
                }
            }
        }
    }

    @Test
    func staticArchives() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourcePath = tmpDir.join("source.c")
            try fs.write(sourcePath, contents: ByteString("extern int main(){}".data(using: String.Encoding.utf8)!))

            let archs = ["x86_64"]

            let objectPaths = [tmpDir.join("你好.o"), tmpDir.join("hello.o"), tmpDir.join("path_that_is_longer_than_16_bytes.o")]
            let machOPath = tmpDir.join("machO.a")
            for objectPath in objectPaths {
                _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang"] + archs.flatMap { ["-arch", $0] } + ["-o", objectPath.str, "-c", sourcePath.str])
            }
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "libtool", "-static", "-o", machOPath.str] + objectPaths.map { $0.str })

            let files: [BinaryReader] = try allReaders(machOPath)

            for file in files {
                let machO = try MachO(reader: file)
                let linkage = try machO.slicesIncludingLinkage().linkage
                #expect(linkage == .static)

                let archive = try StaticArchive(reader: file)
                #expect(!archive.archiveType.isFatArchive)
                let machOs = try archive.machOs()

                #expect(machOs.count == archs.count * objectPaths.count)

                let slices = try machOs.flatMap { try $0.slices() }
                let uuids = try Set(slices.compactMap { (slice) -> NSUUID? in
                    if let uuidString = try slice.uuid()?.description {
                        return NSUUID(uuidString: uuidString)
                    }
                    return nil
                })
                #expect(uuids.isEmpty)

                for machO in machOs {
                    for slice in try machO.slices() {
                        let libs = try slice.linkedLibraryPaths()
                        #expect(libs.isEmpty)

                        let loadCommands = try slice.loadCommands()
                        #expect(loadCommands.filter { [LC_SEGMENT, LC_SEGMENT_64].contains(Int32($0.base.cmd)) }.count == 1)
                        #expect(loadCommands.filter { $0.base.cmd == LC_SYMTAB }.count == 1)

                        let _ = try slice.segments()
                        let _ = try slice.segments().map { try $0.sections() }

                        #expect(try slice.swiftABIVersion() == nil)
                    }
                }
            }
        }
    }

    @Test
    func nonSwift() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourcePath = tmpDir.join("source.c")
            try fs.write(sourcePath, contents: ByteString("int main(){}".data(using: String.Encoding.utf8)!))

            let archs = [
                // "armv7", // TODO: how should we determine which archs to test against?
                // We could read libSystem from the iOS SDK but still need to
                // map arch names to cputype/cpusubtype constants
                "arm64"
            ]
            #expect(!archs.isEmpty)

            let machOPath = tmpDir.join("machO")
            let _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "iphoneos", "clang"] + archs.flatMap { ["-arch", $0] } + ["-framework", "Foundation", "-o", machOPath.str, sourcePath.str])

            let expectedUUIDs: Set<NSUUID> = try await Set(
                archs.asyncMap({ try await InstalledXcode.currentlySelected().xcrun(["otool", "-arch", $0, "-l", machOPath.str]) }).reduce("", { $0 + $1 })
                    .components(separatedBy: "\n")
                    .filter{ $0.contains("    uuid ") }
                    .map{ $0.replacingOccurrences(of: "    uuid ", with: "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                    .map{ NSUUID(uuidString: $0)! })

            let files: [BinaryReader] = try allReaders(machOPath)

            for file in files {
                let machO = try MachO(reader: file)
                let slices = try machO.slices()

                #expect(slices.count == archs.count)
                let uuids = try Set(slices.map{ NSUUID(uuidString: try $0.uuid()!.description)! })
                #expect(expectedUUIDs == uuids)

                for slice in slices {
                    let libs = try slice.linkedLibraryPaths()
                    #expect(libs.contains("/System/Library/Frameworks/Foundation.framework/Foundation"), "libs: \(libs)")

                    #expect(try slice.swiftABIVersion() == nil)
                }
            }
        }
    }

    // Extract the expected Swift ABI version from the test bundle itself.
    private func expectedBinaryInfo(infoLookup: any PlatformInfoLookup) throws -> ([String], SwiftABIVersion?) {
        final class BundleType {}
        let testBundle = Bundle(for: BundleType.self)
        let files: [BinaryReader] = try allReaders(Path(testBundle.executablePath!))
        #expect(files.count > 0)
        let machO = try MachO(reader: files.first!)

        let slices = try machO.slices()
        #expect(slices.count > 0)
        return (try slices[0].targetTripleStrings(infoLookup: infoLookup), try slices[0].swiftABIVersion())
    }

    @Test
    func swiftABIVersion() async throws {
        struct Lookup: PlatformInfoLookup {
            func lookupPlatformInfo(platform: BuildVersion.Platform) -> (any PlatformInfoProvider)? {
                nil
            }
        }
        let (expectedTargets, expectedSwiftABIVersion) = try expectedBinaryInfo(infoLookup: Lookup())
        #expect(!expectedTargets.isEmpty)
        #expect(expectedSwiftABIVersion != nil)
        try await withTemporaryDirectory { tmpDir in
            let sourcePath = tmpDir.join("main.swift")
            try fs.write(sourcePath, contents: ByteString([]))

            let machOPath = tmpDir.join("machO")
            let _ = try await InstalledXcode.currentlySelected().xcrun(["swiftc", "-target", expectedTargets[0], "-o", machOPath.str, sourcePath.str])

            let files: [BinaryReader] = try allReaders(machOPath)

            for file in files {
                let machO = try MachO(reader: file)
                let slices = try machO.slices()
                #expect(slices.count > 0)

                for slice in slices {
                    #expect(try slice.swiftABIVersion() == expectedSwiftABIVersion)
                }
            }
        }
    }

    @Test
    func deploymentTarget() async throws {
        try await withTemporaryDirectory { path in
            let expectedVersion = Version(11, 2, 3)
            try localFS.write(path.join("main.c"), contents: "int main() { return 0; }")
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang", "-target", "\(#require(Architecture.host.stringValue))-apple-macos\(expectedVersion)", "main.c"], workingDirectory: path.str)
            let machOPath = path.join("a.out")

            let files: [BinaryReader] = try allReaders(machOPath)
            #expect(files.count > 0)

            for file in files {
                let machO = try MachO(reader: file)
                let slices = try machO.slices()
                #expect(slices.count > 0)

                for slice in slices {
                    let buildVersions = try slice.buildVersions()
                    #expect(buildVersions.count > 0)

                    for buildVersion in buildVersions {
                        #expect(buildVersion.minOSVersion == expectedVersion)
                    }
                }
            }
        }
    }

    @Test
    func rPaths() async throws {
        try await withTemporaryDirectory { path in
            try localFS.write(path.join("main.c"), contents: "int main() { return 0; }")
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang", "-target", "\(#require(Architecture.host.stringValue))-apple-macos11.0", "-rpath", "@loader_path/Frameworks", "-rpath", "@loader_path/../Frameworks", "main.c"], workingDirectory: path.str)
            let machOPath = path.join("a.out")

            let files: [BinaryReader] = try allReaders(machOPath)
            #expect(files.count > 0)

            for file in files {
                let machO = try MachO(reader: file)
                let slices = try machO.slices()
                #expect(slices.count > 0)

                for slice in slices {
                    let rpaths = try slice.rpaths()
                    #expect(rpaths == [
                        "@loader_path/Frameworks",
                        "@loader_path/../Frameworks"
                    ])
                }
            }
        }
    }

    @Test
    func atomInfo() async throws {
        try await withTemporaryDirectory { path in
            try localFS.write(path.join("file.c"), contents: "const int foo = 0;")
            _ = try await InstalledXcode.currentlySelected().xcrun(["-sdk", "macosx", "clang", "-target", "\(#require(Architecture.host.stringValue))-apple-macos11.0", "-dynamiclib", "-Xlinker", "-make_mergeable", "file.c"], workingDirectory: path.str)
            let machOPath = path.join("a.out")

            let files: [BinaryReader] = try allReaders(machOPath)
            #expect(files.count > 0)

            for file in files {
                let machO = try MachO(reader: file)
                let slices = try machO.slices()
                #expect(slices.count > 0)

                for slice in slices {
                    #expect(try slice.containsAtomInfo())
                }
            }
        }
    }

    @Test
    func nonMachO() throws {
        let files: [BinaryReader] = try [
            // Wrong header
            ByteString("foobar".data(using: String.Encoding.utf8)!),

            // Too short
            ByteString("".data(using: String.Encoding.utf8)!),
        ].flatMap{ try allReaders($0) }

        for file in files {
            #expect(throws: (any Error).self) {
                try MachO(reader: file)
            }
        }
    }

    @Test
    func errors() throws {
        // Thin Mach-O with no content should throw an error when being inspected.
        do {
            func checkError(_ error: any Error) -> Bool {
                switch error {
                case BinaryReaderError.invalidPeek:
                    return String(describing: error) == "Invalid read request. startingAt: 0, offsetBy: 0, typeSize: 28 (mach_header), dataSize: 4"
                default:
                    Issue.record("Unexpected error thrown: \(error)")
                    return false
                }
            }

            let machO = try MachO(data: ByteString([0xfe, 0xed, 0xfa, 0xce]))
            #expect("Reading the data from an empty Mach-O should have thrown", performing: { try machO.slices() }, throws: { (error) in
                checkError(error)
            })
        }

        // A fat Mach-O with no content should throw an error when being inspected..
        do {
            func checkError(_ error: any Error) -> Bool {
                switch error {
                case BinaryReaderError.invalidPeek:
                    return String(describing: error) == "Invalid read request. startingAt: 0, offsetBy: 0, typeSize: 8 (fat_header), dataSize: 4"
                default:
                    Issue.record("Unexpected error thrown: \(error)")
                    return false
                }
            }

            let machO = try MachO(data: ByteString([0xca, 0xfe, 0xba, 0xbe]))
            #expect("Reading the data from an empty fat-archive should have thrown", performing: { try machO.slices() }, throws: { (error) in
                checkError(error)
            })
        }

        // A fat Mach-O that contains a static archive should error when there is no further data`.
        do {
            func checkError(_ error: any Error) -> Bool {
                switch error {
                case BinaryReaderError.invalidRead:
                    return String(describing: error) == "Attempting to read past the size of the binary data. startingAt: 56, typeSize: 60 (ar_hdr), dataSize: 56"
                default:
                    Issue.record("Unexpected error thrown: \(error)")
                    return false
                }
            }

            let machO = try MachO(data: ByteString([
                0xCA, 0xFE, 0xBA, 0xBE, // [0x0000,  0] fat_header.magic
                0x00, 0x00, 0x00, 0x02, // [0x0004,  4] fat_header.nfat_arch (2)

                0x01, 0x00, 0x00, 0x07, // [0x0008,  8] fat_arch.cputype (0x01000007 == CPU_TYPE_X86_64)
                0x00, 0x00, 0x00, 0x03, // [0x000C, 12] fat_arch.cpusubtype (0x00000003 == CPU_SUBTYPE_I386_ALL)
                0x00, 0x00, 0x00, 0x30, // [0x0010, 16] fat_arch.offset (0x30 == 48)
                0x00, 0x00, 0x05, 0xF8, // [0x0014, 20] fat_arch.size (0x05F8 == 1528)
                0x00, 0x00, 0x00, 0x03, // [0x0018, 24] fat_arch.align (0x03 == 3)

                0x01, 0x00, 0x00, 0x07, // [0x001C, 28] fat_arch.cputype (0x01000007 == CPU_TYPE_X86_64)
                0x00, 0x00, 0x00, 0x08, // [0x0020, 32] fat_arch.cpusubtype (0x00000008 == CPU_SUBTYPE_X86_64_H)
                0x00, 0x00, 0x06, 0x28, // [0x0024, 36] fat_arch.offset (0x0628 == 1576)
                0x00, 0x00, 0x06, 0x08, // [0x0028, 40] fat_arch.size (0x0608 == 1544)
                0x00, 0x00, 0x00, 0x03, // [0x002C, 44] fat_arch.align (0x03 == 3)

                0x21, 0x3C, 0x61, 0x72, // [0x0030, 48] // ARMAG1
                0x63, 0x68, 0x3E, 0x0A, // [0x0034, 52] // ARMAG2
            ]))
            #expect("Reading the data from an empty fat-archive should have thrown", performing: { try machO.slices() }, throws: { (error) in
                checkError(error)
            })
        }

        // A fat Mach-O that contains a static archive should error when there is no further data`.
        // It should fail to read past the archive header, though, NOT fail attempting to read a hidden fat_arch because there isn't enough space to read one between the end of the fat_arch list and the start of the first slice (size of fat_arch is 20, or 24 for fat_arch_64).
        do {
            func checkError(_ error: any Error) -> Bool {
                switch error {
                case BinaryReaderError.invalidRead:
                    return String(describing: error) == "Attempting to read past the size of the binary data. startingAt: 60, typeSize: 60 (ar_hdr), dataSize: 60"
                default:
                    Issue.record("Unexpected error thrown: \(error)")
                    return false
                }
            }

            let machO = try MachO(data: ByteString([
                0xCA, 0xFE, 0xBA, 0xBE, // [0x0000,  0] fat_header.magic
                0x00, 0x00, 0x00, 0x02, // [0x0004,  4] fat_header.nfat_arch (2)

                0x01, 0x00, 0x00, 0x07, // [0x0008,  8] fat_arch.cputype (0x01000007 == CPU_TYPE_X86_64)
                0x00, 0x00, 0x00, 0x03, // [0x000C, 12] fat_arch.cpusubtype (0x00000003 == CPU_SUBTYPE_I386_ALL)
                0x00, 0x00, 0x00, 0x34, // [0x0010, 16] fat_arch.offset (0x34 == 52)
                0x00, 0x00, 0x05, 0xF8, // [0x0014, 20] fat_arch.size (0x05F8 == 1528)
                0x00, 0x00, 0x00, 0x03, // [0x0018, 24] fat_arch.align (0x03 == 3)

                0x01, 0x00, 0x00, 0x07, // [0x001C, 28] fat_arch.cputype (0x01000007 == CPU_TYPE_X86_64)
                0x00, 0x00, 0x00, 0x08, // [0x0020, 32] fat_arch.cpusubtype (0x00000008 == CPU_SUBTYPE_X86_64_H)
                0x00, 0x00, 0x06, 0x28, // [0x0024, 36] fat_arch.offset (0x0628 == 1576)
                0x00, 0x00, 0x06, 0x08, // [0x0028, 40] fat_arch.size (0x0608 == 1544)
                0x00, 0x00, 0x00, 0x03, // [0x002C, 44] fat_arch.align (0x03 == 3)

                0x00, 0x00, 0x00, 0x00, // [0x0030, 48] (zero padding)

                0x21, 0x3C, 0x61, 0x72, // [0x0034, 52] ARMAG1
                0x63, 0x68, 0x3E, 0x0A, // [0x0038, 56] ARMAG2
            ]))
            #expect("Reading the data from an empty fat-archive should have thrown", performing: { try machO.slices() }, throws: { (error) in
                checkError(error)
            })
        }
    }

    @Test
    func fixedSizeCArrayStringParsing() throws {
        // Some MachO structs include arrays of chars with a fixed size known at compile time. We need to know to parse no more than necessary even if there's no nil-terminator.

        let expectedName = Array<String>(repeating: "x", count: 16).joined()

        var cmd = segment_command()
        let _ = withUnsafeMutableBytes(of: &cmd) { memset($0.baseAddress!, Int32(expectedName.unicodeScalars.first!.value), MemoryLayout<segment_command>.size) }

        #expect(try expectedName == cmd.segname())
    }

    @Test
    func binaryReader() throws {
        let data = ByteString([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x05, 0xF8, 0x00, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x06, 0x28, 0x00, 0x00, 0x06, 0x08, 0x00, 0x00, 0x00, 0x03, 0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A])
        let reader = BinaryReader(data: data)

        let value1: UInt8 = try reader.read()
        #expect(value1 == 0xCA)
        #expect(reader.cursor.startingOffset == 0)
        #expect(reader.cursor.offset == 1)

        let value2: UInt32 = try reader.peek()
        #expect(value2 == 0x00BEBAFE)
        #expect(reader.cursor.startingOffset == 0)
        #expect(reader.cursor.offset == 1)

        let value3: UInt32 = try reader.read()
        #expect(value3 == 0x00BEBAFE)
        #expect(reader.cursor.startingOffset == 0)
        #expect(reader.cursor.offset == 5)

        reader.push()
        #expect(reader.cursor.startingOffset == 5)
        #expect(reader.cursor.offset == 0)

        let value4: UInt32 = try reader.read()
        #expect(value4 == 0x01020000)
        #expect(reader.cursor.startingOffset == 5)
        #expect(reader.cursor.offset == 4)

        reader.push()
        #expect(reader.cursor.startingOffset == 9)
        #expect(reader.cursor.offset == 0)

        let value5: UInt32 = try reader.read()
        #expect(value5 == 0x00070000)
        #expect(reader.cursor.startingOffset == 9)
        #expect(reader.cursor.offset == 4)

        reader.pop()
        #expect(reader.cursor.startingOffset == 5)
        #expect(reader.cursor.offset == 4)

        let value6: UInt32 = try reader.read()
        #expect(value6 == 0x00070000)
        #expect(reader.cursor.startingOffset == 5)
        #expect(reader.cursor.offset == 8)

        reader.pop()
        #expect(reader.cursor.startingOffset == 0)
        #expect(reader.cursor.offset == 5)

        let value7: UInt32 = try reader.read()
        #expect(value7 == 0x01020000)
        #expect(reader.cursor.startingOffset == 0)
        #expect(reader.cursor.offset == 9)
    }

    @Test
    func byteString() throws {
        let bytes = ByteString([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0xDA, 0x0F, 0x02, 0x01])

        let value1: UInt8 = try bytes.read(from: 0)
        #expect(value1 == 0xCA)

        let value2: UInt32 = try bytes.read(from: 0)
        #expect(value2 == 0xBEBAFECA)

        let value3: UInt8 = try bytes.read(from: 5)
        #expect(value3 == 0xDA)

        let value4: UInt32 = try bytes.read(from: 5)
        #expect(value4 == 0x01020FDA)

        do {
            let _ = try bytes.read(from: 6) as UInt32
            Issue.record("this should throw")
        }
        catch {
        }
    }

    @Test
    func byteStringReader() throws {
        let bytes = ByteString([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0xDA, 0x0F, 0x02, 0x01])
        let reader = BinaryReader(data: bytes)

        let value1: UInt8 = try reader.read()
        #expect(value1 == 0xCA)

        let value2: UInt32 = try reader.read()
        #expect(value2 == 0x00BEBAFE)

        try reader.seek(by: -4)
        let value3: UInt32 = try reader.read()
        #expect(value3 == 0x00BEBAFE)

        let value4: UInt32 = try reader.seek(to: 5).read()
        #expect(value4 == 0x01020FDA)

        do {
            let _ = try reader.read() as UInt32
            Issue.record("this should throw")
        }
        catch {
        }
    }

    @Test
    func buildVersionPlatformInit() {
        // This test is to ensure that all of the supported platforms can be converted to from their platform/environment representation.

        let versions: [BuildVersion.Platform: (platform: String, environment: String?)] = [
            BuildVersion.Platform.driverKit: (platform: "driverkit", environment: nil),
            BuildVersion.Platform.iOS: (platform: "ios", environment: nil),
            BuildVersion.Platform.iOSSimulator: (platform: "ios", environment: "simulator"),
            BuildVersion.Platform.macCatalyst: (platform: "ios", environment: "macabi"),
            BuildVersion.Platform.macOS: (platform: "macos", environment: nil),
            BuildVersion.Platform.tvOS: (platform: "tvos", environment: nil),
            BuildVersion.Platform.tvOSSimulator: (platform: "tvos", environment: "simulator"),
            BuildVersion.Platform.watchOS: (platform: "watchos", environment: nil),
            BuildVersion.Platform.watchOSSimulator: (platform: "watchos", environment: "simulator"),
            BuildVersion.Platform.xrOS: (platform: "xros", environment: nil),
            BuildVersion.Platform.xrOSSimulator: (platform: "xros", environment: "simulator"),
        ]

        for (input, data) in versions {
            let converted = BuildVersion.Platform(platform: data.platform, environment: data.environment)
            #expect(input == converted)
        }
    }
}
#endif
