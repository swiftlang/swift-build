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

    public func store(object: ToolchainCASObject) async throws -> ToolchainDataID {
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
        var cObject: llcas_loaded_object_t = .init()
        var error: UnsafeMutablePointer<CChar>? = nil
        switch api.llcas_cas_load_object(cCas, id.id, &cObject, &error) {
        case LLCAS_LOOKUP_RESULT_SUCCESS:
            let bytes = api.llcas_loaded_object_get_data(cCas, cObject)
            let cRefs = api.llcas_loaded_object_get_refs(cCas, cObject)
            var refs: [ToolchainDataID] = []
            for i in 0..<api.llcas_object_refs_get_count(cCas, cRefs) {
                refs.append(.init(id: api.llcas_object_refs_get_id(cCas, cRefs, i)))
            }
            return ToolchainCASObject(data: ByteString(UnsafeRawBufferPointer(start: bytes.data, count: bytes.size)), refs: refs)
        case LLCAS_LOOKUP_RESULT_NOTFOUND:
            return nil
        case LLCAS_LOOKUP_RESULT_ERROR:
            var detailedError: String?
            if let error {
                detailedError = String(cString: error)
                api.llcas_string_dispose(error)
            }
            throw ToolchainCASPluginError.loadFailed(detailedError)
        default:
            throw ToolchainCASPluginError.loadFailed(nil)
        }
    }

    public func cache(objectID: ToolchainDataID, forKeyID key: ToolchainDataID) async throws {
        let keyDigest = api.llcas_objectid_get_digest(cCas, key.id)
        let cancellationHandler = CancellationHandler(api: api)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let box = ContextBox<Void, any Error>(continuation: continuation, llcas_string_dispose: api.llcas_string_dispose)
                var cancellationToken: llcas_cancellable_t? = nil
                api.llcas_actioncache_put_for_digest_async(cCas, keyDigest, objectID.id, false, Unmanaged.passRetained(box).toOpaque(), { ctx, failed, error in
                    let context = Unmanaged<ContextBox<Void, any Error>>.fromOpaque(ctx!).takeRetainedValue()
                    if failed {
                        var detailedError: String?
                        if let error = error {
                            detailedError = String(cString: error)
                            context.llcas_string_dispose(error)
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
        let keyDigest = api.llcas_objectid_get_digest(cCas, keyID.id)
        let cancellationHandler = CancellationHandler(api: api)
        return try await withTaskCancellationHandler(operation: {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolchainDataID?, Error>) in
                let box = ContextBox<ToolchainDataID?, any Error>(continuation: continuation, llcas_string_dispose: api.llcas_string_dispose)
                var cancellationToken: llcas_cancellable_t? = nil
                api.llcas_actioncache_get_for_digest_async(cCas, keyDigest, false, Unmanaged.passRetained(box).toOpaque(), { ctx, lookupResult, objectID, error in
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
                            context.llcas_string_dispose(error)
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
    let llcas_string_dispose: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    init(continuation: CheckedContinuation<T, E>, llcas_string_dispose: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void) where E: Error {
        self.continuation = continuation
        self.llcas_string_dispose = llcas_string_dispose
    }
}

fileprivate final class CancellationHandler: Sendable {
    private let state: LockedValue<UnsafeSendableBox<(cancelled: Bool, cancellationToken: llcas_cancellable_t?)>>
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
