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

import Foundation
import Synchronization
import SWBCSupport
import SWBUtil
import SWBMockCASPluginSupport

/// Bridged from `llcas_cas_options_t`. Collects the options passed to `llcas_cas_options_set_*`
/// prior to `llcas_cas_create`.
final class MockCASOptions {
    var ondiskPath: Path?
    var remoteServicePath: Path?
}

/// An in-memory, per-instance record of a materialized CAS object's data + references, bridged
/// from `llcas_loaded_object_t`. Owns a stable heap allocation so that the pointer returned by
/// `llcas_loaded_object_get_data` remains valid for the lifetime of the owning `MockCAS`.
final class MockCASObjectRecord: @unchecked Sendable {
    let dataBuffer: UnsafeMutableRawBufferPointer
    let dataCount: Int
    let refsRange: Range<Int>

    init(dataBuffer: UnsafeMutableRawBufferPointer, dataCount: Int, refsRange: Range<Int>) {
        self.dataBuffer = dataBuffer
        self.dataCount = dataCount
        self.refsRange = refsRange
    }

    deinit {
        dataBuffer.deallocate()
    }

    var dataPointer: UnsafeRawPointer? {
        UnsafeRawPointer(dataBuffer.baseAddress)
    }
}

/// A heap allocation with a stable address for the lifetime of the box, used for
/// `llcas_digest_t` buffers that `llcas_objectid_get_digest` hands out (which must remain valid
/// for the lifetime of the owning `llcas_cas_t`).
final class MockCASRawBufferBox: @unchecked Sendable {
    let buffer: UnsafeMutableRawBufferPointer

    init(bytes: [UInt8]) {
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { src in
                buffer.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: bytes.count)
            }
        }
    }

    deinit {
        buffer.deallocate()
    }

    var pointer: UnsafePointer<UInt8>? {
        guard let baseAddress = buffer.baseAddress else {
            return nil
        }
        return UnsafePointer(baseAddress.assumingMemoryBound(to: UInt8.self))
    }
}

/// Computes an object's digest from both its own data bytes and its references' digests, matching
/// how a real content-addressed Merkle DAG derives identity: two objects with identical `data` but
/// different `refs` (e.g. a generic type-tag payload wrapping different children) are different
/// objects and must not collide onto the same digest.
func computeDigestHex(for bytes: [UInt8], refDigestHexes: [String]) -> String {
    let hash = SHA256Context()
    hash.add(bytes: ByteString(bytes))
    for refDigestHex in refDigestHexes {
        hash.add(number: refDigestHex.utf8.count)
        hash.add(string: refDigestHex)
    }
    return hash.signature.asString
}

/// Bridged from `llcas_cas_t`. Implements local + "global"/remote dictionary-backed CAS and
/// action-cache storage, with on-disk JSON persistence and a structured call log for testing.
///
/// Object ids (`llcas_objectid_t`/`llcas_loaded_object_t`) are only meaningful within the
/// lifetime of a single `MockCAS` instance (per the plugin API contract), so the digest
/// <-> id registry below is purely in-memory and never persisted. The on-disk JSON stores are
/// digest-keyed instead, and are the actual cross-instance/cross-process source of truth.
final class MockCAS {
    let casPath: Path
    let remotePath: Path?
    private let fs: any FSProxy
    private let localLock: MockCASFileLock
    private let remoteLock: MockCASFileLock?

    private struct State {
        var nextID: UInt64 = 1
        var digestToID: [String: UInt64] = [:]
        var idToDigest: [UInt64: String] = [:]
        var records: [UInt64: MockCASObjectRecord] = [:]
        var refsStorage: [llcas_objectid_t] = []
        var digestBuffers: [UInt64: MockCASRawBufferBox] = [:]
    }

    private let state = SWBMutex<State>(State())

    init(casPath: Path, remotePath: Path?, fs: any FSProxy = localFS) {
        self.casPath = casPath
        self.remotePath = remotePath
        self.fs = fs
        self.localLock = MockCASFileLock(protecting: casPath.join("cas_store.json"))
        self.remoteLock = remotePath.map { MockCASFileLock(protecting: $0.join("global_store.json")) }
    }

    private var localStorePath: Path { casPath.join("cas_store.json") }
    private var callLogPath: Path { casPath.join("call_log.jsonl") }
    private var remoteStorePath: Path? { remotePath?.join("global_store.json") }

    // MARK: - In-memory id <-> digest registry

    /// Assigns (or reuses) a per-instance id for a digest, without touching disk.
    func idForDigest(_ digestHex: String) -> UInt64 {
        state.withLock { state in
            if let existing = state.digestToID[digestHex] {
                return existing
            }
            let id = state.nextID
            state.nextID += 1
            state.digestToID[digestHex] = id
            state.idToDigest[id] = digestHex
            return id
        }
    }

    func digestHex(forID id: UInt64) -> String? {
        state.withLock { $0.idToDigest[id] }
    }

    func record(forID id: UInt64) -> MockCASObjectRecord? {
        state.withLock { $0.records[id] }
    }

    func refID(atAbsoluteIndex index: Int) -> llcas_objectid_t {
        state.withLock { $0.refsStorage[index] }
    }

    /// Returns a stable `(pointer, size)` for the raw digest bytes of `id`'s digest hex string,
    /// allocating the backing buffer on first access. The buffer stays valid for the lifetime of
    /// this `MockCAS` instance.
    func digestBytesPointer(forID id: UInt64) -> (UnsafePointer<UInt8>?, Int)? {
        state.withLock { state in
            guard let digestHex = state.idToDigest[id] else {
                return nil
            }
            let box: MockCASRawBufferBox
            if let existing = state.digestBuffers[id] {
                box = existing
            } else {
                let rawBytes = hexDecodedBytes(digestHex) ?? []
                box = MockCASRawBufferBox(bytes: rawBytes)
                state.digestBuffers[id] = box
            }
            return (box.pointer, digestHex.utf8.count / 2)
        }
    }

    /// Materializes an object's data + references in-memory for `id`, allocating a stable buffer.
    /// `refDigestHexes` are the hex digests of the object's references; ids are assigned/reused
    /// for them as needed. No-op if `id` is already materialized.
    @discardableResult
    func materialize(id: UInt64, data: [UInt8], refDigestHexes: [String]) -> MockCASObjectRecord {
        state.withLock { state in
            if let existing = state.records[id] {
                return existing
            }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count + 1, alignment: 8)
            if !data.isEmpty {
                data.withUnsafeBytes { src in
                    buffer.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: data.count)
                }
            }
            buffer[data.count] = 0
            let refIDs: [llcas_objectid_t] = refDigestHexes.map { refDigestHex in
                let refID: UInt64
                if let existing = state.digestToID[refDigestHex] {
                    refID = existing
                } else {
                    refID = state.nextID
                    state.nextID += 1
                    state.digestToID[refDigestHex] = refID
                    state.idToDigest[refID] = refDigestHex
                }
                return llcas_objectid_t(opaque: refID)
            }
            let start = state.refsStorage.count
            state.refsStorage.append(contentsOf: refIDs)
            let record = MockCASObjectRecord(dataBuffer: buffer, dataCount: data.count, refsRange: start..<state.refsStorage.count)
            state.records[id] = record
            return record
        }
    }

    // MARK: - On-disk persistence

    private func readStore(at path: Path) throws -> MockCASPersistedStore {
        guard fs.exists(path) else {
            return MockCASPersistedStore()
        }
        let bytes = try fs.read(path)
        return try JSONDecoder().decode(MockCASPersistedStore.self, from: Data(bytes.bytes))
    }

    private func writeStore(_ store: MockCASPersistedStore, to path: Path) throws {
        try fs.createDirectory(path.dirname, recursive: true)
        let data = try JSONEncoder().encode(store)
        try fs.write(path, contents: ByteString(data))
    }

    /// Reads the local JSON store under the local file lock.
    func readLocalStore() throws -> MockCASPersistedStore {
        try localLock.withLock { try readStore(at: localStorePath) }
    }

    /// Runs `body` under the local file lock, giving it read-modify-write access to the local
    /// JSON store, and persists whatever `body` leaves it with.
    func mutateLocalStore<T>(_ body: (inout MockCASPersistedStore) throws -> T) throws -> T {
        try localLock.withLock {
            var store = try readStore(at: localStorePath)
            let result = try body(&store)
            try writeStore(store, to: localStorePath)
            return result
        }
    }

    /// Reads the remote JSON store under the remote file lock. Returns `nil` if no remote path is
    /// configured.
    func readRemoteStore() throws -> MockCASPersistedStore? {
        guard let remoteStorePath, let remoteLock else {
            return nil
        }
        return try remoteLock.withLock { try readStore(at: remoteStorePath) }
    }

    /// Runs `body` under the remote file lock (if a remote path is configured), giving it
    /// read-modify-write access to the remote JSON store, and persists whatever `body` leaves it
    /// with. Returns `nil` if no remote path is configured.
    func mutateRemoteStore<T>(_ body: (inout MockCASPersistedStore) throws -> T) throws -> T? {
        guard let remoteStorePath, let remoteLock else {
            return nil
        }
        return try remoteLock.withLock {
            var store = try readStore(at: remoteStorePath)
            let result = try body(&store)
            try writeStore(store, to: remoteStorePath)
            return result
        }
    }

    /// Appends an entry to the call log, under the local file lock.
    func appendCallLog(_ entry: MockCASCallLogEntry) {
        do {
            try localLock.withLock {
                try fs.createDirectory(casPath, recursive: true)
                var lineData = try JSONEncoder().encode(entry)
                lineData.append(0x0A)
                if fs.exists(callLogPath) {
                    let existing = try fs.read(callLogPath)
                    try fs.write(callLogPath, contents: ByteString(existing.bytes + [UInt8](lineData)))
                } else {
                    try fs.write(callLogPath, contents: ByteString([UInt8](lineData)))
                }
            }
        } catch {
            // Best-effort logging; failures here shouldn't fail the underlying operation.
        }
    }
}
