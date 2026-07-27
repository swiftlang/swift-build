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

import SWBCSupport
import Synchronization
public import SWBUtil

public final class ToolchainCASPlugin: Sendable {
    private let api: plugin_api_t

    public init(dylib path: Path) throws {
        let dylib = try Library.open(path)
        self.api = try plugin_api_t(dylib)
    }

    public func getVersion() -> (Int, Int) {
        var version: (UInt32, UInt32) = (0, 0)
        api.llcas_get_plugin_version(&version.0, &version.1)
        return (Int(version.0), Int(version.1))
    }

    public func createCAS(path: Path, options: [String: String]) throws -> ToolchainCAS {
        let casOptions = api.llcas_cas_options_create()
        defer {
            api.llcas_cas_options_dispose(casOptions)
        }
        api.llcas_cas_options_set_client_version(casOptions, 0, 1)
        api.llcas_cas_options_set_ondisk_path(casOptions, path.str)
        for (option, value) in options {
            var error: UnsafeMutablePointer<CChar>? = nil
            guard !api.llcas_cas_options_set_option(casOptions, option, value, &error) else {
                var detailedError: String?
                if let error = error {
                    detailedError = String(cString: error)
                    api.llcas_string_dispose(error)
                }
                throw ToolchainCASPluginError.settingCASOptionFailed(detailedError)
            }
        }
        var error: UnsafeMutablePointer<CChar>? = nil
        guard let cCas = api.llcas_cas_create(casOptions, &error) else {
            var detailedError: String?
            if let error = error {
                detailedError = String(cString: error)
                api.llcas_string_dispose(error)
            }
            throw ToolchainCASPluginError.casCreationFailed(detailedError)
        }
        return ToolchainCAS(api: api, cCas: cCas)
    }
}

public final class ToolchainCAS: @unchecked Sendable, CASProtocol, ActionCacheProtocol {
    private let api: plugin_api_t
    private let cCas: llcas_cas_t

    internal init(api: plugin_api_t, cCas: llcas_cas_t) {
        self.api = api
        self.cCas = cCas
    }

    public func printID(_ id: ToolchainDataID) -> String {
        let cDigest = api.llcas_objectid_get_digest(cCas, id.id)
        var cPrintedID: UnsafeMutablePointer<CChar>? = nil
        let failed = api.llcas_digest_print(cCas, cDigest, &cPrintedID, nil)
        // Since we print the digest that we just received, there can't be any error thrown.
        precondition(!failed, "llcas_digest_print failed?")
        let printedID = String(cString: cPrintedID!)
        api.llcas_string_dispose(cPrintedID)
        return printedID
    }

    public func parseID(_ printedID: String) throws -> ByteString {
        // Call to get the buffer size that we need.
        let digestSize = Int(api.llcas_digest_parse(cCas, printedID, nil, 0, nil))
        let bytes = try [UInt8](unsafeUninitializedCapacity: digestSize) { buffer, initializedCount in
            var error: UnsafeMutablePointer<CChar>? = nil
            let bytesCount = api.llcas_digest_parse(cCas, printedID, buffer.baseAddress, buffer.count, &error)
            guard bytesCount != 0 else {
                var detailedError: String?
                if let error = error {
                    detailedError = String(cString: error)
                    api.llcas_string_dispose(error)
                }
                throw ToolchainCASPluginError.parseIDFailed(detailedError)
            }
            initializedCount = Int(bytesCount)
        }
        return ByteString(bytes)
    }

    public func objectID(forDigest digest: ByteString) throws -> ToolchainDataID {
        return try digest.bytes.withUnsafeBufferPointer { (bytes: UnsafeBufferPointer<UInt8>) in
            var dataID: llcas_objectid_t = .init()
            var error: UnsafeMutablePointer<CChar>? = nil
            guard !api.llcas_cas_get_objectid(cCas, .init(data: bytes.baseAddress, size: bytes.count), &dataID, &error) else {
                var detailedError: String?
                if let error = error {
                    detailedError = String(cString: error)
                    api.llcas_string_dispose(error)
                }
                throw ToolchainCASPluginError.invalidDigest(detailedError)
            }
            return ToolchainDataID(id: dataID)
        }
    }

    public func objectID(forPrintedID printedID: String) throws -> ToolchainDataID {
        let digest = try parseID(printedID)
        return try objectID(forDigest: digest)
    }

    public func isMaterialized(id: ToolchainDataID) throws -> Bool {
        var error: UnsafeMutablePointer<CChar>? = nil
        switch api.llcas_cas_contains_object(cCas, id.id, /*globally*/false, &error) {
        case LLCAS_LOOKUP_RESULT_SUCCESS:
            return true
        case LLCAS_LOOKUP_RESULT_NOTFOUND:
            return false
        case LLCAS_LOOKUP_RESULT_ERROR:
            var detailedError: String?
            if let error {
                detailedError = String(cString: error)
                api.llcas_string_dispose(error)
            }
            throw ToolchainCASPluginError.idLookupFailed(detailedError)
        default:
            throw ToolchainCASPluginError.idLookupFailed(nil)
        }
    }

    public func store(object: ToolchainCASObject) async throws -> ToolchainDataID {
        return try _store(object: object)
    }

    public func store(object: ToolchainCASObject) throws -> ToolchainDataID {
        return try _store(object: object)
    }

    private func _store(object: ToolchainCASObject) throws -> ToolchainDataID {
        var dataID: llcas_objectid_t = .init()
        var error: UnsafeMutablePointer<CChar>? = nil
        try object.data.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard !api.llcas_cas_store_object(cCas, .init(data: bytes.baseAddress, size: bytes.count), object.refs.map(\.id), object.refs.count, &dataID, &error) else {
                var detailedError: String?
                if let error = error {
                    detailedError = String(cString: error)
                    api.llcas_string_dispose(error)
                }
                throw ToolchainCASPluginError.storeFailed(detailedError)
            }
        }
        return ToolchainDataID(id: dataID)
    }

    public func load(id: ToolchainDataID) async throws -> ToolchainCASObject? {
        let cancellationHandler = CancellationHandler(api: api)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolchainCASObject?, Error>) in
                let box = ContextBox<ToolchainCASObject?, any Error>(continuation: continuation, cas: self)
                var cancellationToken: llcas_cancellable_t? = nil
                api.llcas_cas_load_object_async(cCas, id.id, Unmanaged.passRetained(box).toOpaque(), { ctx, lookup_result, cObject, error in
                    let context = Unmanaged<ContextBox<ToolchainCASObject?, any Error>>.fromOpaque(ctx!).takeRetainedValue()
                    let api = context.cas.api
                    let cCas = context.cas.cCas
                    switch lookup_result {
                    case LLCAS_LOOKUP_RESULT_SUCCESS:
                        let bytes = api.llcas_loaded_object_get_data(cCas, cObject)
                        let cRefs = api.llcas_loaded_object_get_refs(cCas, cObject)
                        var refs: [ToolchainDataID] = []
                        for i in 0..<api.llcas_object_refs_get_count(cCas, cRefs) {
                            refs.append(.init(id: api.llcas_object_refs_get_id(cCas, cRefs, i)))
                        }
                        context.continuation.resume(returning: ToolchainCASObject(data: ByteString(UnsafeRawBufferPointer(start: bytes.data, count: bytes.size)), refs: refs))
                    case LLCAS_LOOKUP_RESULT_NOTFOUND:
                        context.continuation.resume(returning: nil)
                    case LLCAS_LOOKUP_RESULT_ERROR:
                        var detailedError: String?
                        if let error {
                            detailedError = String(cString: error)
                            api.llcas_string_dispose(error)
                        }
                        context.continuation.resume(throwing: ToolchainCASPluginError.cacheLookupFailed(detailedError))
                    default:
                        context.continuation.resume(throwing: ToolchainCASPluginError.cacheLookupFailed(nil))
                    }
                }, &cancellationToken)
                if let cancellationToken {
                    cancellationHandler.registerCancellationToken(cancellationToken)
                }
            }
        }, onCancel: {
            cancellationHandler.cancel()
        })
    }

    public func cache(objectID: ToolchainDataID, forKeyID key: ToolchainDataID) async throws {
        let keyDigest = api.llcas_objectid_get_digest(cCas, key.id)
        var error: UnsafeMutablePointer<CChar>? = nil
        guard !api.llcas_actioncache_put_for_digest(cCas, keyDigest, objectID.id, false, &error) else {
            var detailedError: String?
            if let error = error {
                detailedError = String(cString: error)
                api.llcas_string_dispose(error)
            }
            throw ToolchainCASPluginError.cacheInsertionFailed(detailedError)
        }
    }

    public func cacheGlobally(objectID: ToolchainDataID, forKeyID key: ToolchainDataID) async throws {
        let keyDigest = api.llcas_objectid_get_digest(cCas, key.id)
        let cancellationHandler = CancellationHandler(api: api)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let box = ContextBox<Void, any Error>(continuation: continuation, cas: self)
                var cancellationToken: llcas_cancellable_t? = nil
                api.llcas_actioncache_put_for_digest_async(cCas, keyDigest, objectID.id, true, Unmanaged.passRetained(box).toOpaque(), { ctx, failed, error in
                    let context = Unmanaged<ContextBox<Void, any Error>>.fromOpaque(ctx!).takeRetainedValue()
                    if failed {
                        var detailedError: String?
                        if let error = error {
                            detailedError = String(cString: error)
                            context.cas.api.llcas_string_dispose(error)
                        }
                        context.continuation.resume(throwing: ToolchainCASPluginError.cacheInsertionFailed(detailedError))
                    } else {
                        context.continuation.resume(returning: ())
                    }
                }, &cancellationToken)
                if let cancellationToken {
                    cancellationHandler.registerCancellationToken(cancellationToken)
                }
            }
        }, onCancel: {
            cancellationHandler.cancel()
        })
    }

    public func lookupCachedObject(for keyID: ToolchainDataID) async throws -> ToolchainDataID? {
        return try lookupCachedObject(for: keyID, globally: false)
    }

    public func lookupCachedObject(for keyID: ToolchainDataID, globally: Bool) throws -> ToolchainDataID? {
        let keyDigest = api.llcas_objectid_get_digest(cCas, keyID.id)
        var objectID: llcas_objectid_t = .init()
        var error: UnsafeMutablePointer<CChar>? = nil
        switch api.llcas_actioncache_get_for_digest(cCas, keyDigest, &objectID, globally, &error) {
        case LLCAS_LOOKUP_RESULT_SUCCESS:
            return ToolchainDataID(id: objectID)
        case LLCAS_LOOKUP_RESULT_NOTFOUND:
            return nil
        case LLCAS_LOOKUP_RESULT_ERROR:
            var detailedError: String?
            if let error {
                detailedError = String(cString: error)
                api.llcas_string_dispose(error)
            }
            throw ToolchainCASPluginError.cacheLookupFailed(detailedError)
        default:
            throw ToolchainCASPluginError.cacheLookupFailed(nil)
        }
    }

    public func lookupCachedObjectGlobally(for keyID: ToolchainDataID) async throws -> ToolchainDataID? {
        let keyDigest = api.llcas_objectid_get_digest(cCas, keyID.id)
        let cancellationHandler = CancellationHandler(api: api)
        return try await withTaskCancellationHandler(operation: {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolchainDataID?, Error>) in
                let box = ContextBox<ToolchainDataID?, any Error>(continuation: continuation, cas: self)
                var cancellationToken: llcas_cancellable_t? = nil
                api.llcas_actioncache_get_for_digest_async(cCas, keyDigest, true, Unmanaged.passRetained(box).toOpaque(), { ctx, lookupResult, objectID, error in
                    let context = Unmanaged<ContextBox<ToolchainDataID?, any Error>>.fromOpaque(ctx!).takeRetainedValue()
                    switch lookupResult {
                    case LLCAS_LOOKUP_RESULT_SUCCESS:
                        context.continuation.resume(returning: ToolchainDataID(id: objectID))
                    case LLCAS_LOOKUP_RESULT_NOTFOUND:
                        context.continuation.resume(returning: nil)
                    case LLCAS_LOOKUP_RESULT_ERROR:
                        var detailedError: String?
                        if let error {
                            detailedError = String(cString: error)
                            context.cas.api.llcas_string_dispose(error)
                        }
                        context.continuation.resume(throwing: ToolchainCASPluginError.cacheLookupFailed(detailedError))
                    default:
                        context.continuation.resume(throwing: ToolchainCASPluginError.cacheLookupFailed(nil))
                    }
                }, &cancellationToken)
                if let cancellationToken {
                    cancellationHandler.registerCancellationToken(cancellationToken)
                }
            }
        }, onCancel: {
            cancellationHandler.cancel()
        })
    }

    public func getOnDiskSize() throws -> Int64 {
        var error: UnsafeMutablePointer<CChar>? = nil
        guard let llcas_cas_get_ondisk_size = api.llcas_cas_get_ondisk_size else {
            throw ToolchainCASPluginError.casSizeOperationUnsupported
        }
        let result = llcas_cas_get_ondisk_size(cCas, &error)
        switch result {
        case -1:
            throw ToolchainCASPluginError.casSizeOperationUnsupported
        case -2:
            if let error = error {
                let detailedError = String(cString: error)
                api.llcas_string_dispose(error)
                throw ToolchainCASPluginError.casSizeOperationFailed(detailedError)
            }
            throw ToolchainCASPluginError.casSizeOperationFailed(nil)
        default:
            return result
        }
    }

    public func setOnDiskSizeLimit(_ limit: Int64) throws {
        var error: UnsafeMutablePointer<CChar>? = nil
        guard let  llcas_cas_set_ondisk_size_limit = api.llcas_cas_set_ondisk_size_limit else {
            throw ToolchainCASPluginError.casSizeOperationUnsupported
        }
        if llcas_cas_set_ondisk_size_limit(cCas, limit, &error) {
            if let error = error {
                let detailedError = String(cString: error)
                api.llcas_string_dispose(error)
                throw ToolchainCASPluginError.casSizeOperationFailed(detailedError)
            }
            throw ToolchainCASPluginError.casSizeOperationFailed(nil)
        }
    }

    public func prune() throws {
        var error: UnsafeMutablePointer<CChar>? = nil
        guard let llcas_cas_prune_ondisk_data = api.llcas_cas_prune_ondisk_data else {
            throw ToolchainCASPluginError.casPruneOperationUnsupported
        }
        if llcas_cas_prune_ondisk_data(cCas, &error) {
            if let error = error {
                let detailedError = String(cString: error)
                api.llcas_string_dispose(error)
                throw ToolchainCASPluginError.casPruneOperationFailed(detailedError)
            }
            throw ToolchainCASPluginError.casPruneOperationFailed(nil)
        }
    }

    public var supportsPruning: Bool {
        api.llcas_cas_get_ondisk_size != nil && api.llcas_cas_set_ondisk_size_limit != nil && api.llcas_cas_prune_ondisk_data != nil
    }

    deinit {
        api.llcas_cas_dispose(cCas)
    }
}

public struct ToolchainDataID: Equatable, Sendable {
    internal let id: llcas_objectid_t

    internal init(id: llcas_objectid_t) {
        self.id = id
    }

    public static func == (lhs: ToolchainDataID, rhs: ToolchainDataID) -> Bool {
        lhs.id.opaque == rhs.id.opaque
    }
}

public struct ToolchainCASObject: Equatable, Sendable, CASObjectProtocol {
    public var data: ByteString
    public var refs: [ToolchainDataID]

    public init(data: ByteString, refs: [ToolchainDataID]) {
        self.data = data
        self.refs = refs
    }
}

fileprivate final class ContextBox<T, E: Error> {
    let continuation: CheckedContinuation<T, E>
    let cas: ToolchainCAS

    init(continuation: CheckedContinuation<T, E>, cas: ToolchainCAS) where E: Error {
        self.continuation = continuation
        self.cas = cas
    }
}

fileprivate final class CancellationHandler: Sendable {
    private let state: SWBMutex<UnsafeSendableBox<(cancelled: Bool, cancellationToken: llcas_cancellable_t?)>>
    private let api: plugin_api_t

    init(api: plugin_api_t) {
        self.state = .init(.init(value: (cancelled: false, cancellationToken: nil)))
        self.api = api
    }

    func cancel() {
        state.withLock { state in
            state.value.cancelled = true
            if let cancellationToken = state.value.cancellationToken {
                api.llcas_cancellable_cancel?(cancellationToken)
            }
        }
    }

    func registerCancellationToken(_ token: llcas_cancellable_t) {
        let box = UnsafeSendableBox(value: token)
        state.withLock { state in
            state.value.cancellationToken = box.value
            if state.value.cancelled {
                api.llcas_cancellable_cancel?(box.value)
            }
        }
    }

    deinit {
        state.withLock { state in
            if let cancellationToken = state.value.cancellationToken {
                api.llcas_cancellable_dispose?(cancellationToken)
            }
        }
    }
}

fileprivate struct UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T

    init(value: T) {
        self.value = value
    }
}
