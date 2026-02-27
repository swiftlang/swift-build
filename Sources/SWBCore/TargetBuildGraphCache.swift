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

import SWBUtil

/// Process-level cache for computed target dependency graphs.
///
/// Clients issue multiple `TargetBuildGraph` requests per build action
/// with different parameters (e.g. dependency graph analysis vs actual
/// build). A multi-entry cache ensures these don't evict each other.
///
/// The cache is static (process-level) because `WorkspaceContext` is
/// recreated on every PIF transfer, even when nothing has changed.
public enum TargetBuildGraphCache {
    /// The data we cache — everything needed by the
    /// `TargetBuildGraph` memberwise init except the live context
    /// objects (workspaceContext, buildRequest, buildRequestContext).
    struct CachedDependencyGraph: @unchecked Sendable {
        let allTargets: OrderedSet<ConfiguredTarget>
        let targetDependencies:
            [ConfiguredTarget: [ResolvedTargetDependency]]
        let targetsToLinkedReferencesToProducingTargets:
            [ConfiguredTarget:
                [BuildFile.BuildableItem: ResolvedTargetDependency]]
        let dynamicallyBuildingTargets: Set<Target>
        /// All non-error diagnostics emitted during resolution,
        /// re-emitted on cache hit.
        let diagnostics: [Diagnostic]
        /// Last access time for LRU eviction.
        var lastAccess: UInt64
    }

    /// Maximum number of cached entries. Xcode typically issues 2-4
    /// distinct graph requests per build action; 8 gives headroom.
    private static let maxEntries = 8

    private static let entries =
        SWBMutex<[Int: CachedDependencyGraph]>([:])
    private static let accessCounter = SWBMutex<UInt64>(0)

    /// Bump and return the next access timestamp for LRU tracking.
    private static func nextAccessTime() -> UInt64 {
        accessCounter.withLock { counter in
            counter += 1
            return counter
        }
    }

    /// Look up a cached dependency graph by signature.
    static func lookup(signature: Int) -> CachedDependencyGraph? {
        entries.withLock { entries in
            guard var entry = entries[signature] else { return nil }
            entry.lastAccess = nextAccessTime()
            entries[signature] = entry
            return entry
        }
    }

    /// Store a computed dependency graph for the given signature.
    static func store(signature: Int, graph: CachedDependencyGraph) {
        entries.withLock { entries in
            if entries.count >= maxEntries {
                // LRU eviction — remove the least recently accessed
                // entry instead of clearing the entire cache.
                if let lruKey = entries.min(
                    by: { $0.value.lastAccess < $1.value.lastAccess }
                )?.key {
                    entries.removeValue(forKey: lruKey)
                }
            }
            entries[signature] = graph
        }
    }

    /// Whether the given build command should bypass the cache.
    /// Index preparation (prepareForIndexing) uses low QoS and
    /// produces large dependency graphs that are rarely reused —
    /// the memory overhead of caching them is not worth it.
    static func shouldSkipCache(buildCommand: BuildCommand) -> Bool {
        buildCommand.isPrepareForIndexing
    }

    /// Compute a cache signature from the inputs that determine the
    /// dependency graph.
    ///
    /// The dependency graph is a pure function of the PIF structure
    /// and the build request parameters. File contents (source files,
    /// resources) do not affect which targets exist or how they depend
    /// on each other — only the PIF does.
    static func computeSignature(
        workspaceSignature: String,
        workspaceIdentity: ObjectIdentifier,
        buildRequest: BuildRequest,
        purpose: TargetBuildGraph.Purpose
    ) -> Int {
        var hasher = Hasher()

        // Use the full workspace signature AND the workspace object
        // identity. The cached graph stores live ConfiguredTarget
        // objects whose Target references use reference identity
        // (ObjectIdentifier) for hash/equality. If the PIF is
        // re-transferred, the IncrementalPIFLoader may create new
        // Target objects even when the content is unchanged — the
        // workspace signature stays the same but the references are
        // different. Including the object identity ensures we miss
        // whenever the Workspace (and its Target objects) is recreated.
        hasher.combine(workspaceSignature)
        hasher.combine(workspaceIdentity)

        // Global build parameters
        hasher.combine(buildRequest.parameters)

        // Top-level build targets and their per-target parameters.
        // Preserve input order — it affects the output target
        // ordering in the resolved dependency graph (manual build
        // ordering), so different orderings must produce different
        // cache signatures.
        for targetInfo in buildRequest.buildTargets {
            hasher.combine(targetInfo.target.guid)
            hasher.combine(targetInfo.parameters)
        }

        // Flags that affect graph topology
        hasher.combine(buildRequest.useImplicitDependencies)
        hasher.combine(buildRequest.useParallelTargets)
        hasher.combine(buildRequest.skipDependencies)

        // Dependency scope affects pruning
        hasher.combine(buildRequest.dependencyScope)

        // Build command affects the early-return for
        // assembly/preprocessor. BuildCommand has associated values
        // that prevent auto-Hashable, so we hash only the
        // discriminator which is what affects graph topology.
        switch buildRequest.buildCommand {
        case .build:
            hasher.combine("build")
        case .generateAssemblyCode:
            hasher.combine("asm")
        case .generatePreprocessedFile:
            hasher.combine("preprocess")
        case .singleFileBuild:
            hasher.combine("single")
        case .prepareForIndexing:
            hasher.combine("index")
        case .cleanBuildFolder:
            hasher.combine("clean")
        case .preview:
            hasher.combine("preview")
        }

        // Purpose affects diagnostic behavior
        hasher.combine(purpose)

        return hasher.finalize()
    }
}
