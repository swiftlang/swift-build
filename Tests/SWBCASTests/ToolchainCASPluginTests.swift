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
fileprivate struct ToolchainCASPluginTests {
    private func pluginPath() async throws -> Path {
        if let pathString = getEnvironmentVariable("TOOLCHAIN_CAS_PLUGIN_PATH") {
            return Path(pathString)
        }
        return try await Xcode.getActiveDeveloperDirectoryPath().join("usr/lib/libToolchainCASPlugin.dylib")
    }

    @Test func loadingPlugin() async throws {
        let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
        let _ = casPlugin.getVersion()
    }

    @Test func CASBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let object1 = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            let id1 = try await cas.store(object: object1)
            let loadedObject1 = try await cas.load(id: id1)
            #expect(object1 == loadedObject1)
            let object2 = ToolchainCASObject(data: [10, 9, 8, 7], refs: [id1])
            let id2 = try await cas.store(object: object2)
            let loadedObject2 = try await cas.load(id: id2)
            #expect(object2 == loadedObject2)
        }
    }

    @Test func actionCacheBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try await pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let value = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            let objectID = try await cas.store(object: value)
            let key = ToolchainCASObject(data: [10, 9, 8, 7], refs: [])
            let keyID = try await cas.store(object: key)
            try await cas.cache(objectID: objectID, forKeyID: keyID)
            let retrievedObjectID = try await cas.lookupCachedObject(for: keyID)
            #expect(objectID == retrievedObjectID)
        }
    }
}
