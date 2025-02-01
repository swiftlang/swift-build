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

@Suite(.performance, .requireHostOS(.macOS, when: getEnvironmentVariable("TOOLCHAIN_CAS_PLUGIN_PATH") == nil), .disabled(if: getEnvironmentVariable("CI") != nil, "Test is too expensive to run in CI"))
fileprivate struct CASFSNodePerfTests: PerfTests {
    private func pluginPath() async throws -> Path {
        if let pathString = getEnvironmentVariable("TOOLCHAIN_CAS_PLUGIN_PATH") {
            return Path(pathString)
        }
        return try await Xcode.getActiveDeveloperDirectoryPath().join("usr/lib/libToolchainCASPlugin.dylib")
    }

    func randomBytes(_ count: Int) -> ByteString {
        var rng = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _  in 0..<count {
            bytes.append(UInt8.random(in: 0...UInt8.max, using: &rng))
        }
        return ByteString(bytes)
    }

    @Test
    func largeFileExportPerf() async throws {
        try await withTemporaryDirectory { tempDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
            let _ = casPlugin.getVersion()
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            let path1 = tempDir.join("A")
            let randomData = randomBytes(1024 * 1024 * 1024)
            try localFS.write(path1, contents: randomData)
            let nodeID = try await CASFSNode.import(path: path1, fs: localFS, cas: cas)
            let exportDir = tempDir.join("export")
            try await measure {
                let node = try await CASFSNode.load(id: nodeID, cas: cas)
                try localFS.createDirectory(exportDir)
                try await node.export(into: exportDir, fs: localFS, cas: cas)
            }
            #expect(try localFS.read(path1) == localFS.read(exportDir.join("A")))
        }
    }

    @Test
    func largeFileImportPerf() async throws {
        try await withTemporaryDirectory { tempDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
            let _ = casPlugin.getVersion()
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            let path1 = tempDir.join("A")
            let randomData = randomBytes(1024 * 1024 * 1024)
            try localFS.write(path1, contents: randomData)
            let nodeIDPromise = Promise<ToolchainDataID, any Error>()
            await measure {
                await nodeIDPromise.fulfill(with: Result.catching({ try await CASFSNode.import(path: path1, fs: localFS, cas: cas) }))
            }
            let nodeID = try await nodeIDPromise.value
            let exportDir = tempDir.join("export")
            let node = try await CASFSNode.load(id: nodeID, cas: cas)
            try localFS.createDirectory(exportDir)
            try await node.export(into: exportDir, fs: localFS, cas: cas)
            #expect(try localFS.read(path1) == localFS.read(exportDir.join("A")))
        }
    }

    @Test
    func largeDirectoryHierarchyExportPerf() async throws {
        try await withTemporaryDirectory { tempDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
            let _ = casPlugin.getVersion()
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            let path1 = tempDir.join("0")
            try localFS.createDirectory(path1)
            for i in 0..<100 {
                let path2 = path1.join("\(i)")
                try localFS.createDirectory(path2)
                for j in 0..<100 {
                    let path3 = path2.join("\(j)")
                    try localFS.write(path3, contents: "hello, world!")
                }
            }
            let nodeID = try await CASFSNode.import(path: path1, fs: localFS, cas: cas)
            try await measure {
                let exportDir = tempDir.join("export")
                let node = try await CASFSNode.load(id: nodeID, cas: cas)
                try localFS.createDirectory(exportDir)
                try await node.export(into: exportDir, fs: localFS, cas: cas)
            }
        }
    }

    @Test
    func largeDirectoryHierarchyImportPerf() async throws {
        try await withTemporaryDirectory { tempDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
            let _ = casPlugin.getVersion()
            let cas = try casPlugin.createCAS(path: tempDir.join("cas"), options: [:])
            let path1 = tempDir.join("0")
            try localFS.createDirectory(path1)
            for i in 0..<100 {
                let path2 = path1.join("\(i)")
                try localFS.createDirectory(path2)
                for j in 0..<100 {
                    let path3 = path2.join("\(j)")
                    try localFS.write(path3, contents: "hello, world!")
                }
            }
            let nodeIDPromise = Promise<ToolchainDataID, any Error>()
            await measure {
                await nodeIDPromise.fulfill(with: Result.catching({ try await CASFSNode.import(path: path1, fs: localFS, cas: cas) }))
            }
            let nodeID = try await nodeIDPromise.value
            let exportDir = tempDir.join("export")
            let node = try await CASFSNode.load(id: nodeID, cas: cas)
            try localFS.createDirectory(exportDir)
            try await node.export(into: exportDir, fs: localFS, cas: cas)
        }
    }
}
