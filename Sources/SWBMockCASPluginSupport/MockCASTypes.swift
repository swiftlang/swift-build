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

/// A record of a single `llcas_*` API call made against `MockToolchainCASPlugin`, persisted to
/// `call_log.jsonl` so that tests can verify which operations occurred.
public struct MockCASCallLogEntry: Codable, Sendable, Equatable {
    /// The name of the `llcas_*` function that was invoked, e.g. `"llcas_cas_store_object"`.
    public var function: String

    /// The `globally` hint that was passed to the call, if applicable.
    public var globally: Bool?

    /// The hex digest of the action cache key involved in the call, if applicable.
    public var keyDigest: String?

    /// The hex digest of the action cache value involved in the call, if applicable.
    public var valueDigest: String?

    /// The hex digest of the CAS object involved in the call, if applicable.
    public var objectDigest: String?

    /// The outcome of the call: `"success"`, `"notfound"`, `"error"`, or `"void"`.
    public var outcome: String

    /// Which storage tier actually satisfied the call: `"local"` or `"remote"`.
    public var source: String?

    /// A human readable error message, if `outcome == "error"`.
    public var errorMessage: String?

    public init(function: String, globally: Bool? = nil, keyDigest: String? = nil, valueDigest: String? = nil, objectDigest: String? = nil, outcome: String, source: String? = nil, errorMessage: String? = nil) {
        self.function = function
        self.globally = globally
        self.keyDigest = keyDigest
        self.valueDigest = valueDigest
        self.objectDigest = objectDigest
        self.outcome = outcome
        self.source = source
        self.errorMessage = errorMessage
    }
}

/// The on-disk JSON representation of a single stored CAS object.
public struct MockCASPersistedObject: Codable, Sendable, Equatable {
    /// Base64-encoded object data.
    public var data: String

    /// Hex digests of the object's references, in order.
    public var refs: [String]

    public init(data: String, refs: [String]) {
        self.data = data
        self.refs = refs
    }
}

/// The on-disk JSON representation of a CAS + action cache store (used for both the local store
/// and the "global"/remote store).
public struct MockCASPersistedStore: Codable, Sendable, Equatable {
    /// Hex digest -> stored object.
    public var objects: [String: MockCASPersistedObject]

    /// Hex digest of action cache key -> hex digest of action cache value.
    public var actionCache: [String: String]

    public init(objects: [String: MockCASPersistedObject] = [:], actionCache: [String: String] = [:]) {
        self.objects = objects
        self.actionCache = actionCache
    }
}

/// Collects `digestHex`'s persisted object plus every object transitively reachable through its
/// refs, by walking `store.objects`. Operates on a persisted store snapshot (rather than any single
/// process's in-memory records) because the object that needs uploading may have been materialized
/// by a different process sharing the same on-disk CAS path (e.g. a compiler subprocess with its
/// own separate CAS instance) — the on-disk store is the actual cross-process source of truth.
public func persistedObjectClosure(in store: MockCASPersistedStore, startingAt digestHex: String) -> [String: MockCASPersistedObject] {
    var result: [String: MockCASPersistedObject] = [:]
    var visited: Set<String> = []
    var pending: [String] = [digestHex]
    while let current = pending.popLast() {
        guard visited.insert(current).inserted else { continue }
        guard let object = store.objects[current] else { continue }
        result[current] = object
        pending.append(contentsOf: object.refs)
    }
    return result
}
