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

import Testing
import SWBCAS
import SWBUtil
import SWBTestSupport
import SWBMockCASPluginSupport

/// Validates `MockToolchainCASPlugin` against the same behavioral contract that
/// `ToolchainCASPluginTests` validates the real plugin against.
@Suite
fileprivate struct MockToolchainCASPluginTests {
    private func pluginPath() throws -> Path {
        try MockCASPluginLocator.locate()
    }

    @Test func CASBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
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
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
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

    @Test func syncStore() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let object = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            // Disambiguate from the `async` overload of `store(object:)` via an explicit non-async function type.
            let syncStore: (ToolchainCASObject) throws -> ToolchainDataID = cas.store(object:)
            let id = try syncStore(object)
            let loadedObject = try await cas.load(id: id)
            #expect(object == loadedObject)
        }
    }

    @Test func printAndParseID() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let object = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            let id = try await cas.store(object: object)

            let printedID = cas.printID(id)
            #expect(!printedID.isEmpty)

            let digest = try cas.parseID(printedID)
            let idFromDigest = try cas.objectID(forDigest: digest)
            #expect(idFromDigest == id)

            let idFromPrintedID = try cas.objectID(forPrintedID: printedID)
            #expect(idFromPrintedID == id)
        }
    }

    @Test func isMaterialized() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let object = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            let id = try await cas.store(object: object)
            #expect(try cas.isMaterialized(id: id))

            // Flip a byte of a real digest to get a well-formed digest that was never stored.
            var unstoredDigestBytes = try cas.parseID(cas.printID(id)).bytes
            unstoredDigestBytes[0] ^= 0xFF
            let unstoredID = try cas.objectID(forDigest: ByteString(unstoredDigestBytes))
            #expect(try !cas.isMaterialized(id: unstoredID))
        }
    }

    @Test func actionCacheGlobally() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let value = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            let objectID = try await cas.store(object: value)
            let key = ToolchainCASObject(data: [10, 9, 8, 7], refs: [])
            let keyID = try await cas.store(object: key)

            try await cas.cacheGlobally(objectID: objectID, forKeyID: keyID)

            let retrievedAsync = try await cas.lookupCachedObjectGlobally(for: keyID)
            #expect(objectID == retrievedAsync)

            let retrievedSync = try cas.lookupCachedObject(for: keyID, globally: true)
            #expect(objectID == retrievedSync)
        }
    }

    @Test func lookupCachedObjectSyncNotFound() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let key = ToolchainCASObject(data: [42], refs: [])
            let keyID = try await cas.store(object: key)
            let result = try cas.lookupCachedObject(for: keyID, globally: false)
            #expect(result == nil)
        }
    }

    @Test func callLogRecordsOperations() async throws {
        try await withTemporaryDirectory { tmpDir in
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())
            let cas = try casPlugin.createCAS(path: tmpDir, options: [:])
            let object = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            let id = try await cas.store(object: object)
            _ = try await cas.load(id: id)

            let entries = try readCallLog(at: tmpDir)
            #expect(entries.contains { $0.function == "llcas_cas_store_object" && $0.outcome == "success" })
            #expect(entries.contains { $0.function == "llcas_cas_load_object_async" && $0.outcome == "success" && $0.source == "local" })
        }
    }

    @Test func remoteActionCacheHitIsRecordedAsRemote() async throws {
        try await withTemporaryDirectory { tmpDir in
            let localPath1 = tmpDir.join("local1")
            let localPath2 = tmpDir.join("local2")
            let remotePath = tmpDir.join("remote")
            let casPlugin = try ToolchainCASPlugin(dylib: try pluginPath())

            let cas1 = try casPlugin.createCAS(path: localPath1, options: ["remote-service-path": remotePath.str])
            let value = ToolchainCASObject(data: [1, 2, 3, 4], refs: [])
            let objectID = try await cas1.store(object: value)
            let key = ToolchainCASObject(data: [10, 9, 8, 7], refs: [])
            let keyID = try await cas1.store(object: key)
            try await cas1.cacheGlobally(objectID: objectID, forKeyID: keyID)

            let cas2 = try casPlugin.createCAS(path: localPath2, options: ["remote-service-path": remotePath.str])
            let keyID2 = try cas2.objectID(forDigest: try cas2.parseID(cas1.printID(keyID)))
            let retrieved = try cas2.lookupCachedObject(for: keyID2, globally: true)
            #expect(retrieved != nil)

            let entries = try readCallLog(at: localPath2)
            #expect(entries.contains { $0.function == "llcas_actioncache_get_for_digest" && $0.outcome == "success" && $0.source == "remote" })
        }
    }
}
