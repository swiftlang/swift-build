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

import Testing
import SWBCAS
import SWBUtil
import SWBTestSupport

@Suite(.requireHostOS(.macOS, when: getEnvironmentVariable("TOOLCHAIN_CAS_PLUGIN_PATH") == nil), .requireXcode16())
fileprivate struct CASFSNodeTests {
    private func pluginPath() async throws -> Path {
        if let pathString = getEnvironmentVariable("TOOLCHAIN_CAS_PLUGIN_PATH") {
            return Path(pathString)
        }
        return try await Xcode.getActiveDeveloperDirectoryPath().join("usr/lib/libToolchainCASPlugin.dylib")
    }

    @Test func fileBasics() async throws {
        let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
        let _ = casPlugin.getVersion()

        try await withTemporaryDirectory { tempDir in
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            let path1 = tempDir.join("A.txt")
            try localFS.write(path1, contents: "Hello, world!")
            let nodeID = try await CASFSNode.import(path: path1, fs: localFS, cas: cas)
            let node = try await CASFSNode.load(id: nodeID, cas: cas)
            let exportDir = tempDir.join("export")
            try localFS.createDirectory(exportDir)
            try await node.export(into: exportDir, fs: localFS, cas: cas)
            #expect(try localFS.read(path1) == localFS.read(exportDir.join("A.txt")))
        }
    }

    @Test func directoryBasics() async throws {
        let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
        let _ = casPlugin.getVersion()

        try await withTemporaryDirectory { tempDir in
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            try localFS.createDirectory(tempDir.join("A"))
            try localFS.createDirectory(tempDir.join("A/B"))
            try localFS.write(tempDir.join("A/1.txt"), contents: "1")
            try localFS.write(tempDir.join("A/2.txt"), contents: "2")
            try localFS.write(tempDir.join("A/B/3.txt"), contents: "3")
            let nodeID = try await CASFSNode.import(path: tempDir.join("A"), fs: localFS, cas: cas)
            let node = try await CASFSNode.load(id: nodeID, cas: cas)
            try localFS.createDirectory(tempDir.join("export"))
            try await node.export(into: tempDir.join("export"), fs: localFS, cas: cas)
            #expect(try localFS.read(tempDir.join("export/A/1.txt")) == "1")
            #expect(try localFS.read(tempDir.join("export/A/2.txt")) == "2")
            #expect(try localFS.read(tempDir.join("export/A/B/3.txt")) == "3")
        }
    }

    @Test func symlinkBasics() async throws {
        let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
        let _ = casPlugin.getVersion()

        try await withTemporaryDirectory { tempDir in
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            try localFS.createDirectory(tempDir.join("A"))
            try localFS.createDirectory(tempDir.join("A/B"))
            try localFS.write(tempDir.join("A/B/1.txt"), contents: "1")
            try localFS.symlink(tempDir.join("A/1.txt"), target: Path("B/1.txt"))
            let nodeID = try await CASFSNode.import(path: tempDir.join("A"), fs: localFS, cas: cas)
            let node = try await CASFSNode.load(id: nodeID, cas: cas)
            try localFS.createDirectory(tempDir.join("export"))
            try await node.export(into: tempDir.join("export"), fs: localFS, cas: cas)
            #expect(try localFS.read(tempDir.join("A/B/1.txt")) == "1")
            #expect(localFS.isSymlink(tempDir.join("A/1.txt")))
            #expect(try localFS.read(tempDir.join("A/1.txt")) == "1")
        }
    }

    @Test func directoryImportIsIndependentOfListingOrder() async throws {
        let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())

        try await withTemporaryDirectory { tempDir in
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            // Create the same tree twice with the entries in a different order.
            for (dir, names) in [("A", ["1.txt", "2.txt", "3.txt"]), ("B", ["3.txt", "1.txt", "2.txt"])] {
                let root = tempDir.join(dir).join("root")
                try localFS.createDirectory(root, recursive: true)
                for name in names {
                    try localFS.write(root.join(name), contents: ByteString(encodingAsUTF8: name))
                }
            }
            let a = try await CASFSNode.import(path: tempDir.join("A/root"), fs: localFS, cas: cas)
            let b = try await CASFSNode.import(path: tempDir.join("B/root"), fs: localFS, cas: cas)
            #expect(a == b)
            #expect(try await CASFSNode.differences(between: a, and: b, cas: cas).isEmpty)
        }
    }

    @Test func differences() async throws {
        let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())

        try await withTemporaryDirectory { tempDir in
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            for dir in ["A", "B"] {
                let root = tempDir.join(dir).join("root")
                try localFS.createDirectory(root.join("sub"), recursive: true)
                try localFS.write(root.join("same.txt"), contents: "same")
                try localFS.write(root.join("sub/changed.txt"), contents: ByteString(encodingAsUTF8: dir))
                try localFS.write(root.join("only-\(dir).txt"), contents: "only")
            }
            let a = try await CASFSNode.import(path: tempDir.join("A/root"), fs: localFS, cas: cas)
            let b = try await CASFSNode.import(path: tempDir.join("B/root"), fs: localFS, cas: cas)
            #expect(try await CASFSNode.differences(between: a, and: b, cas: cas) == [Path("only-A.txt"), Path("only-B.txt"), Path("sub/changed.txt")])

            let fileA = try await CASFSNode.import(path: tempDir.join("A/root/sub/changed.txt"), fs: localFS, cas: cas)
            let fileB = try await CASFSNode.import(path: tempDir.join("B/root/sub/changed.txt"), fs: localFS, cas: cas)
            #expect(try await CASFSNode.differences(between: fileA, and: fileB, cas: cas) == [Path("")])
            #expect(try await CASFSNode.differences(between: fileA, and: fileA, cas: cas).isEmpty)
        }
    }
}
