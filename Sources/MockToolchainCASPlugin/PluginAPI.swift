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

// Implementation of the `llcas_*` C ABI (see `Sources/SWBCSupport/PluginAPI*.h`) backed by
// dictionaries persisted to JSON, for use in local testing of swift-build's compilation caching
// (including the `globally: true` remote-cache code paths, simulated via a second on-disk
// dictionary rooted at the `remote-service-path` custom option).
//
// Object ids (`llcas_objectid_t`) are only meaningful within the lifetime of the `llcas_cas_t`
// that produced them, so digests are used as the canonical, persistable identifier: the digest
// bytes are the raw SHA256 hash bytes, and `llcas_digest_print`/`llcas_digest_parse` hex-encode
// and hex-decode them. Digest bytes handed to this plugin aren't assumed to always originate from
// a prior call into this plugin (e.g. a caller may compute a digest independently), so digest
// identity is always derived via a lossless byte-for-byte hex encoding, never a UTF8 decode.

import Foundation
public import SWBCSupport
import SWBLibc
import SWBUtil
import SWBMockCASPluginSupport

private func unwrapOptions(_ options: llcas_cas_options_t) -> MockCASOptions {
    Unmanaged<MockCASOptions>.fromOpaque(UnsafeRawPointer(options)).takeUnretainedValue()
}

private func unwrapCAS(_ cas: llcas_cas_t) -> MockCAS {
    Unmanaged<MockCAS>.fromOpaque(UnsafeRawPointer(cas)).takeUnretainedValue()
}

private func setOutError(_ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ message: String) {
    outError?.pointee = strdup(message)
}

private func dataBytes(_ data: llcas_data_t) -> [UInt8] {
    guard let base = data.data, data.size > 0 else {
        return []
    }
    return [UInt8](UnsafeRawBufferPointer(start: base, count: data.size))
}

private let debugTraceEnabled = ProcessInfo.processInfo.environment["MOCKCAS_TRACE"] != nil

private func debugTrace(_ message: @autoclosure () -> String) {
    if debugTraceEnabled {
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }
}

private func previewBytes(_ bytes: [UInt8], limit: Int = 60) -> String {
    let truncated = bytes.prefix(limit)
    let text = String(decoding: truncated, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n")
    return "\(bytes.count) bytes: \(text)\(bytes.count > limit ? "..." : "")"
}

private func digestHexString(_ digest: llcas_digest_t) -> String? {
    guard let base = digest.data else {
        return nil
    }
    // `digest`'s bytes aren't guaranteed to be valid UTF8 (e.g. a caller may pass a raw,
    // independently-computed hash), so hex-encode byte-for-byte rather than UTF8-decode, which
    // would lossily collapse distinct invalid byte sequences and alias unrelated digests together.
    return hexEncodedString(UnsafeBufferPointer(start: base, count: digest.size))
}

@_cdecl("llcas_get_plugin_version")
public func llcas_get_plugin_version(_ major: UnsafeMutablePointer<UInt32>?, _ minor: UnsafeMutablePointer<UInt32>?) {
    major?.pointee = 0
    minor?.pointee = 1
}

@_cdecl("llcas_string_dispose")
public func llcas_string_dispose(_ str: UnsafeMutablePointer<CChar>?) {
    free(str)
}

@_cdecl("llcas_cas_options_create")
public func llcas_cas_options_create() -> llcas_cas_options_t {
    llcas_cas_options_t(Unmanaged.passRetained(MockCASOptions()).toOpaque())
}

@_cdecl("llcas_cas_options_dispose")
public func llcas_cas_options_dispose(_ options: llcas_cas_options_t) {
    Unmanaged<MockCASOptions>.fromOpaque(UnsafeRawPointer(options)).release()
}

@_cdecl("llcas_cas_options_set_client_version")
public func llcas_cas_options_set_client_version(_ options: llcas_cas_options_t, _ major: UInt32, _ minor: UInt32) {
    // The mock doesn't need to validate client/plugin version compatibility.
}

@_cdecl("llcas_cas_options_set_ondisk_path")
public func llcas_cas_options_set_ondisk_path(_ options: llcas_cas_options_t, _ path: UnsafePointer<CChar>?) {
    guard let path else {
        return
    }
    unwrapOptions(options).ondiskPath = Path(String(cString: path))
}

@_cdecl("llcas_cas_options_set_option")
public func llcas_cas_options_set_option(_ options: llcas_cas_options_t, _ name: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    guard let name, let value else {
        setOutError(outError, "llcas_cas_options_set_option: missing name or value")
        return true
    }
    // Mirrors the option key that `CASOptions.getRemoteServicePluginOption` sends; treated as a
    // directory holding the "global"/remote store, to simulate a remote caching service.
    if String(cString: name) == "remote-service-path" {
        unwrapOptions(options).remoteServicePath = Path(String(cString: value))
    }
    return false
}

@_cdecl("llcas_cas_create")
public func llcas_cas_create(_ options: llcas_cas_options_t, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> llcas_cas_t? {
    let opts = unwrapOptions(options)
    guard let ondiskPath = opts.ondiskPath else {
        setOutError(outError, "llcas_cas_create: llcas_cas_options_set_ondisk_path was not called")
        return nil
    }
    let cas = MockCAS(casPath: ondiskPath, remotePath: opts.remoteServicePath)
    debugTrace("cas_create: casPath=\(ondiskPath.str) remotePath=\(opts.remoteServicePath?.str ?? "nil")")
    return llcas_cas_t(Unmanaged.passRetained(cas).toOpaque())
}

@_cdecl("llcas_cas_dispose")
public func llcas_cas_dispose(_ cas: llcas_cas_t) {
    Unmanaged<MockCAS>.fromOpaque(UnsafeRawPointer(cas)).release()
}

@_cdecl("llcas_cas_get_hash_schema_name")
public func llcas_cas_get_hash_schema_name(_ cas: llcas_cas_t) -> UnsafeMutablePointer<CChar>? {
    strdup("MockCAS-SHA256")
}

@_cdecl("llcas_digest_parse")
public func llcas_digest_parse(_ cas: llcas_cas_t, _ printedDigest: UnsafePointer<CChar>?, _ bytes: UnsafeMutablePointer<UInt8>?, _ bytesSize: Int, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UInt32 {
    guard let printedDigest else {
        setOutError(outError, "llcas_digest_parse: missing printed digest")
        return 0
    }
    // The printed digest is the hex encoding of the raw digest bytes, so parsing hex-decodes it.
    guard let rawBytes = hexDecodedBytes(String(cString: printedDigest)) else {
        setOutError(outError, "llcas_digest_parse: printed digest is not valid hex")
        return 0
    }
    guard bytesSize >= rawBytes.count else {
        debugTrace("digest_parse: printed=\(String(cString: printedDigest)) querySize (bytesSize=\(bytesSize)) -> needs \(rawBytes.count)")
        return UInt32(rawBytes.count)
    }
    if let bytes {
        for i in 0..<rawBytes.count {
            bytes[i] = rawBytes[i]
        }
    }
    debugTrace("digest_parse: printed=\(String(cString: printedDigest)) -> wrote \(rawBytes.count) bytes")
    return UInt32(rawBytes.count)
}

@_cdecl("llcas_digest_print")
public func llcas_digest_print(_ cas: llcas_cas_t, _ digest: llcas_digest_t, _ printedID: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    guard let digestHex = digestHexString(digest) else {
        setOutError(outError, "llcas_digest_print: missing digest bytes")
        return true
    }
    printedID?.pointee = strdup(digestHex)
    debugTrace("digest_print: rawSize=\(digest.size) -> printed=\(digestHex)")
    return false
}

@_cdecl("llcas_cas_get_objectid")
public func llcas_cas_get_objectid(_ cas: llcas_cas_t, _ digest: llcas_digest_t, _ pID: UnsafeMutablePointer<llcas_objectid_t>?, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    guard let digestHex = digestHexString(digest) else {
        setOutError(outError, "llcas_cas_get_objectid: missing digest bytes")
        return true
    }
    let id = unwrapCAS(cas).idForDigest(digestHex)
    pID?.pointee = llcas_objectid_t(opaque: id)
    debugTrace("get_objectid: digest=\(digestHex) rawSize=\(digest.size) -> id=\(id)")
    return false
}

@_cdecl("llcas_objectid_get_digest")
public func llcas_objectid_get_digest(_ cas: llcas_cas_t, _ id: llcas_objectid_t) -> llcas_digest_t {
    guard let (pointer, size) = unwrapCAS(cas).digestBytesPointer(forID: id.opaque) else {
        debugTrace("objectid_get_digest: id=\(id.opaque) -> MISSING")
        return llcas_digest_t(data: nil, size: 0)
    }
    debugTrace("objectid_get_digest: id=\(id.opaque) -> digest=\(unwrapCAS(cas).digestHex(forID: id.opaque) ?? "?") size=\(size)")
    return llcas_digest_t(data: pointer, size: size)
}

@_cdecl("llcas_cas_contains_object")
public func llcas_cas_contains_object(_ cas: llcas_cas_t, _ id: llcas_objectid_t, _ globally: Bool, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> llcas_lookup_result_t {
    let mockCAS = unwrapCAS(cas)
    guard let digestHex = mockCAS.digestHex(forID: id.opaque) else {
        setOutError(outError, "llcas_cas_contains_object: unknown object id")
        return LLCAS_LOOKUP_RESULT_ERROR
    }
    do {
        let localStore = try mockCAS.readLocalStore()
        if localStore.objects[digestHex] != nil {
            mockCAS.appendCallLog(MockCASCallLogEntry(function: "llcas_cas_contains_object", globally: globally, objectDigest: digestHex, outcome: "success", source: "local"))
            debugTrace("contains_object: id=\(id.opaque) digest=\(digestHex) globally=\(globally) -> LOCAL")
            return LLCAS_LOOKUP_RESULT_SUCCESS
        }
        if globally, let remoteStore = try mockCAS.readRemoteStore(), remoteStore.objects[digestHex] != nil {
            mockCAS.appendCallLog(MockCASCallLogEntry(function: "llcas_cas_contains_object", globally: globally, objectDigest: digestHex, outcome: "success", source: "remote"))
            debugTrace("contains_object: id=\(id.opaque) digest=\(digestHex) globally=\(globally) -> REMOTE")
            return LLCAS_LOOKUP_RESULT_SUCCESS
        }
        mockCAS.appendCallLog(MockCASCallLogEntry(function: "llcas_cas_contains_object", globally: globally, objectDigest: digestHex, outcome: "notfound"))
        debugTrace("contains_object: id=\(id.opaque) digest=\(digestHex) globally=\(globally) -> NOTFOUND")
        return LLCAS_LOOKUP_RESULT_NOTFOUND
    } catch {
        mockCAS.appendCallLog(MockCASCallLogEntry(function: "llcas_cas_contains_object", globally: globally, objectDigest: digestHex, outcome: "error", errorMessage: "\(error)"))
        setOutError(outError, "\(error)")
        return LLCAS_LOOKUP_RESULT_ERROR
    }
}

/// Shared logic for `llcas_cas_load_object`/`_async`: local check first, unconditional fallback
/// to remote on miss (this function has no `globally` parameter), materializing a remote hit into
/// the local store before returning.
private func performLoadObject(_ mockCAS: MockCAS, id: llcas_objectid_t, functionName: String) -> (llcas_lookup_result_t, llcas_loaded_object_t, String?) {
    guard let digestHex = mockCAS.digestHex(forID: id.opaque) else {
        debugTrace("\(functionName): id=\(id.opaque) -> UNKNOWN ID")
        return (LLCAS_LOOKUP_RESULT_ERROR, llcas_loaded_object_t(), "\(functionName): unknown object id")
    }
    do {
        let localStore = try mockCAS.readLocalStore()
        if let object = localStore.objects[digestHex] {
            guard let data = Data(base64Encoded: object.data) else {
                return (LLCAS_LOOKUP_RESULT_ERROR, llcas_loaded_object_t(), "\(functionName): corrupt local store entry")
            }
            mockCAS.materialize(id: id.opaque, data: [UInt8](data), refDigestHexes: object.refs)
            mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, objectDigest: digestHex, outcome: "success", source: "local"))
            debugTrace("\(functionName): id=\(id.opaque) digest=\(digestHex) -> LOCAL HIT \(previewBytes([UInt8](data))) refs=\(object.refs)")
            return (LLCAS_LOOKUP_RESULT_SUCCESS, llcas_loaded_object_t(opaque: id.opaque), nil)
        }
        if let remoteObject = try mockCAS.readRemoteStore()?.objects[digestHex] {
            guard let data = Data(base64Encoded: remoteObject.data) else {
                return (LLCAS_LOOKUP_RESULT_ERROR, llcas_loaded_object_t(), "\(functionName): corrupt remote store entry")
            }
            try mockCAS.mutateLocalStore { store in
                store.objects[digestHex] = remoteObject
            }
            mockCAS.materialize(id: id.opaque, data: [UInt8](data), refDigestHexes: remoteObject.refs)
            mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, objectDigest: digestHex, outcome: "success", source: "remote"))
            debugTrace("\(functionName): id=\(id.opaque) digest=\(digestHex) -> REMOTE HIT \(previewBytes([UInt8](data))) refs=\(remoteObject.refs)")
            return (LLCAS_LOOKUP_RESULT_SUCCESS, llcas_loaded_object_t(opaque: id.opaque), nil)
        }
        mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, objectDigest: digestHex, outcome: "notfound"))
        debugTrace("\(functionName): id=\(id.opaque) digest=\(digestHex) -> NOTFOUND")
        return (LLCAS_LOOKUP_RESULT_NOTFOUND, llcas_loaded_object_t(), nil)
    } catch {
        mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, objectDigest: digestHex, outcome: "error", errorMessage: "\(error)"))
        return (LLCAS_LOOKUP_RESULT_ERROR, llcas_loaded_object_t(), "\(error)")
    }
}

@_cdecl("llcas_cas_load_object")
public func llcas_cas_load_object(_ cas: llcas_cas_t, _ id: llcas_objectid_t, _ pObject: UnsafeMutablePointer<llcas_loaded_object_t>?, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> llcas_lookup_result_t {
    let (result, object, errorMessage) = performLoadObject(unwrapCAS(cas), id: id, functionName: "llcas_cas_load_object")
    if let errorMessage {
        setOutError(outError, errorMessage)
    }
    pObject?.pointee = object
    return result
}

// Implemented synchronously: the callback is invoked before returning, and `cancelTok` is never
// populated (both are spec-legal, per the header's "whether the call is asynchronous or not
// depends on the implementation").
@_cdecl("llcas_cas_load_object_async")
public func llcas_cas_load_object_async(_ cas: llcas_cas_t, _ id: llcas_objectid_t, _ ctxCB: UnsafeMutableRawPointer?, _ callback: llcas_cas_load_object_cb?, _ cancelTok: UnsafeMutablePointer<llcas_cancellable_t?>?) {
    let (result, object, errorMessage) = performLoadObject(unwrapCAS(cas), id: id, functionName: "llcas_cas_load_object_async")
    callback?(ctxCB, result, object, errorMessage.map { strdup($0) })
}

@_cdecl("llcas_cas_store_object")
public func llcas_cas_store_object(_ cas: llcas_cas_t, _ data: llcas_data_t, _ refs: UnsafePointer<llcas_objectid_t>?, _ refsCount: Int, _ pID: UnsafeMutablePointer<llcas_objectid_t>?, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    let mockCAS = unwrapCAS(cas)
    let bytes = dataBytes(data)
    var refDigestHexes: [String] = []
    if let refs, refsCount > 0 {
        for i in 0..<refsCount {
            guard let refDigestHex = mockCAS.digestHex(forID: refs[i].opaque) else {
                setOutError(outError, "llcas_cas_store_object: unknown reference object id")
                return true
            }
            refDigestHexes.append(refDigestHex)
        }
    }
    let digestHex = computeDigestHex(for: bytes, refDigestHexes: refDigestHexes)
    do {
        try mockCAS.mutateLocalStore { store in
            store.objects[digestHex] = MockCASPersistedObject(data: Data(bytes).base64EncodedString(), refs: refDigestHexes)
        }
        mockCAS.appendCallLog(MockCASCallLogEntry(function: "llcas_cas_store_object", objectDigest: digestHex, outcome: "success"))
    } catch {
        mockCAS.appendCallLog(MockCASCallLogEntry(function: "llcas_cas_store_object", objectDigest: digestHex, outcome: "error", errorMessage: "\(error)"))
        setOutError(outError, "\(error)")
        return true
    }
    let id = mockCAS.idForDigest(digestHex)
    mockCAS.materialize(id: id, data: bytes, refDigestHexes: refDigestHexes)
    pID?.pointee = llcas_objectid_t(opaque: id)
    debugTrace("store_object: digest=\(digestHex) -> id=\(id) \(previewBytes(bytes)) refs=\(refDigestHexes)")
    return false
}

@_cdecl("llcas_loaded_object_get_data")
public func llcas_loaded_object_get_data(_ cas: llcas_cas_t, _ object: llcas_loaded_object_t) -> llcas_data_t {
    guard let record = unwrapCAS(cas).record(forID: object.opaque) else {
        debugTrace("loaded_object_get_data: id=\(object.opaque) -> MISSING RECORD")
        return llcas_data_t(data: nil, size: 0)
    }
    debugTrace("loaded_object_get_data: id=\(object.opaque) digest=\(unwrapCAS(cas).digestHex(forID: object.opaque) ?? "?") -> \(previewBytes([UInt8](UnsafeRawBufferPointer(start: record.dataPointer, count: record.dataCount))))")
    return llcas_data_t(data: record.dataPointer, size: record.dataCount)
}

@_cdecl("llcas_loaded_object_get_refs")
public func llcas_loaded_object_get_refs(_ cas: llcas_cas_t, _ object: llcas_loaded_object_t) -> llcas_object_refs_t {
    guard let record = unwrapCAS(cas).record(forID: object.opaque) else {
        debugTrace("loaded_object_get_refs: id=\(object.opaque) -> MISSING RECORD")
        return llcas_object_refs_t(opaque_b: 0, opaque_e: 0)
    }
    debugTrace("loaded_object_get_refs: id=\(object.opaque) digest=\(unwrapCAS(cas).digestHex(forID: object.opaque) ?? "?") -> range=\(record.refsRange)")
    return llcas_object_refs_t(opaque_b: UInt64(record.refsRange.lowerBound), opaque_e: UInt64(record.refsRange.upperBound))
}

@_cdecl("llcas_object_refs_get_count")
public func llcas_object_refs_get_count(_ cas: llcas_cas_t, _ refs: llcas_object_refs_t) -> Int {
    Int(refs.opaque_e - refs.opaque_b)
}

@_cdecl("llcas_object_refs_get_id")
public func llcas_object_refs_get_id(_ cas: llcas_cas_t, _ refs: llcas_object_refs_t, _ index: Int) -> llcas_objectid_t {
    let refID = unwrapCAS(cas).refID(atAbsoluteIndex: Int(refs.opaque_b) + index)
    debugTrace("object_refs_get_id: range=[\(refs.opaque_b), \(refs.opaque_e)) index=\(index) -> id=\(refID.opaque) digest=\(unwrapCAS(cas).digestHex(forID: refID.opaque) ?? "?")")
    return refID
}

/// Shared logic for `llcas_actioncache_get_for_digest`/`_async`: local lookup, falling back to
/// the remote action-cache map on miss when `globally` is set, pulling a remote hit's association
/// into the local action cache.
private func performActionCacheGet(_ mockCAS: MockCAS, key: llcas_digest_t, globally: Bool, functionName: String) -> (llcas_lookup_result_t, llcas_objectid_t, String?) {
    guard let keyDigestHex = digestHexString(key) else {
        return (LLCAS_LOOKUP_RESULT_ERROR, llcas_objectid_t(), "\(functionName): missing key digest bytes")
    }
    do {
        let localStore = try mockCAS.readLocalStore()
        if let valueDigestHex = localStore.actionCache[keyDigestHex] {
            let valueID = mockCAS.idForDigest(valueDigestHex)
            mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, globally: globally, keyDigest: keyDigestHex, valueDigest: valueDigestHex, outcome: "success", source: "local"))
            debugTrace("\(functionName): casPath=\(mockCAS.casPath.str) globally=\(globally) key=\(keyDigestHex) -> LOCAL HIT value=\(valueDigestHex)")
            return (LLCAS_LOOKUP_RESULT_SUCCESS, llcas_objectid_t(opaque: valueID), nil)
        }
        if globally, let remoteStore = try mockCAS.readRemoteStore(), let valueDigestHex = remoteStore.actionCache[keyDigestHex] {
            try mockCAS.mutateLocalStore { store in
                store.actionCache[keyDigestHex] = valueDigestHex
            }
            let valueID = mockCAS.idForDigest(valueDigestHex)
            mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, globally: globally, keyDigest: keyDigestHex, valueDigest: valueDigestHex, outcome: "success", source: "remote"))
            debugTrace("\(functionName): casPath=\(mockCAS.casPath.str) globally=\(globally) key=\(keyDigestHex) -> REMOTE HIT value=\(valueDigestHex)")
            return (LLCAS_LOOKUP_RESULT_SUCCESS, llcas_objectid_t(opaque: valueID), nil)
        }
        mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, globally: globally, keyDigest: keyDigestHex, outcome: "notfound"))
        debugTrace("\(functionName): casPath=\(mockCAS.casPath.str) globally=\(globally) key=\(keyDigestHex) -> NOTFOUND")
        return (LLCAS_LOOKUP_RESULT_NOTFOUND, llcas_objectid_t(), nil)
    } catch {
        mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, globally: globally, keyDigest: keyDigestHex, outcome: "error", errorMessage: "\(error)"))
        return (LLCAS_LOOKUP_RESULT_ERROR, llcas_objectid_t(), "\(error)")
    }
}

@_cdecl("llcas_actioncache_get_for_digest")
public func llcas_actioncache_get_for_digest(_ cas: llcas_cas_t, _ key: llcas_digest_t, _ pValue: UnsafeMutablePointer<llcas_objectid_t>?, _ globally: Bool, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> llcas_lookup_result_t {
    let (result, value, errorMessage) = performActionCacheGet(unwrapCAS(cas), key: key, globally: globally, functionName: "llcas_actioncache_get_for_digest")
    if let errorMessage {
        setOutError(outError, errorMessage)
    }
    pValue?.pointee = value
    return result
}

@_cdecl("llcas_actioncache_get_for_digest_async")
public func llcas_actioncache_get_for_digest_async(_ cas: llcas_cas_t, _ key: llcas_digest_t, _ globally: Bool, _ ctxCB: UnsafeMutableRawPointer?, _ callback: llcas_actioncache_get_cb?, _ cancelTok: UnsafeMutablePointer<llcas_cancellable_t?>?) {
    let (result, value, errorMessage) = performActionCacheGet(unwrapCAS(cas), key: key, globally: globally, functionName: "llcas_actioncache_get_for_digest_async")
    callback?(ctxCB, result, value, errorMessage.map { strdup($0) })
}

/// Shared logic for `llcas_actioncache_put_for_digest`/`_async`: always writes the local action
/// cache association; when `globally`, also writes the remote action-cache map, and uploads the
/// value object's full transitively-reachable ref graph (not just its own immediate data) into the
/// remote object store, since that's the only way object content becomes remotely visible — a
/// remote consumer that later pulls the key->value association must be able to resolve every
/// object the value references, not just the value itself. The closure is read from the on-disk
/// local store rather than this instance's in-memory records, since the value's refs may have been
/// materialized by a different process (e.g. a compiler subprocess with its own separate `MockCAS`
/// instance) sharing the same local CAS path — the on-disk store is the cross-process source of
/// truth.
private func performActionCachePut(_ mockCAS: MockCAS, key: llcas_digest_t, value: llcas_objectid_t, globally: Bool, functionName: String) -> String? {
    guard let keyDigestHex = digestHexString(key) else {
        return "\(functionName): missing key digest bytes"
    }
    guard let valueDigestHex = mockCAS.digestHex(forID: value.opaque) else {
        return "\(functionName): unknown value object id"
    }
    do {
        try mockCAS.mutateLocalStore { store in
            store.actionCache[keyDigestHex] = valueDigestHex
        }
        if globally {
            let localStore = try mockCAS.readLocalStore()
            let closure = persistedObjectClosure(in: localStore, startingAt: valueDigestHex)
            _ = try mockCAS.mutateRemoteStore { store in
                store.actionCache[keyDigestHex] = valueDigestHex
                for (digestHex, object) in closure {
                    store.objects[digestHex] = object
                }
            }
        }
        mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, globally: globally, keyDigest: keyDigestHex, valueDigest: valueDigestHex, outcome: "success"))
        debugTrace("\(functionName): casPath=\(mockCAS.casPath.str) globally=\(globally) key=\(keyDigestHex) value=\(valueDigestHex)")
        return nil
    } catch {
        mockCAS.appendCallLog(MockCASCallLogEntry(function: functionName, globally: globally, keyDigest: keyDigestHex, valueDigest: valueDigestHex, outcome: "error", errorMessage: "\(error)"))
        return "\(error)"
    }
}

@_cdecl("llcas_actioncache_put_for_digest")
public func llcas_actioncache_put_for_digest(_ cas: llcas_cas_t, _ key: llcas_digest_t, _ value: llcas_objectid_t, _ globally: Bool, _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    if let errorMessage = performActionCachePut(unwrapCAS(cas), key: key, value: value, globally: globally, functionName: "llcas_actioncache_put_for_digest") {
        setOutError(outError, errorMessage)
        return true
    }
    return false
}

@_cdecl("llcas_actioncache_put_for_digest_async")
public func llcas_actioncache_put_for_digest_async(_ cas: llcas_cas_t, _ key: llcas_digest_t, _ value: llcas_objectid_t, _ globally: Bool, _ ctxCB: UnsafeMutableRawPointer?, _ callback: llcas_actioncache_put_cb?, _ cancelTok: UnsafeMutablePointer<llcas_cancellable_t?>?) {
    let errorMessage = performActionCachePut(unwrapCAS(cas), key: key, value: value, globally: globally, functionName: "llcas_actioncache_put_for_digest_async")
    callback?(ctxCB, errorMessage != nil, errorMessage.map { strdup($0) })
}
