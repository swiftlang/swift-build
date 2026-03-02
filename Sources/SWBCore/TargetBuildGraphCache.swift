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

package import SWBUtil

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
    package struct CachedDependencyGraph: @unchecked Sendable {
        /// Signature without workspaceIdentity — used for
        /// content-based remap matching.
        package let contentSignature: Int
        package let allTargets: OrderedSet<ConfiguredTarget>
        package let targetDependencies:
            [ConfiguredTarget: [ResolvedTargetDependency]]
        package let targetsToLinkedReferencesToProducingTargets:
            [ConfiguredTarget:
                [BuildFile.BuildableItem: ResolvedTargetDependency]]
        package let dynamicallyBuildingTargets: Set<Target>
        /// All non-error diagnostics emitted during resolution,
        /// re-emitted on cache hit.
        package let diagnostics: [Diagnostic]
        /// Last access time for LRU eviction.
        package var lastAccess: UInt64

        package init(
            contentSignature: Int,
            allTargets: OrderedSet<ConfiguredTarget>,
            targetDependencies: [ConfiguredTarget:
                [ResolvedTargetDependency]],
            targetsToLinkedReferencesToProducingTargets:
                [ConfiguredTarget:
                    [BuildFile.BuildableItem:
                        ResolvedTargetDependency]],
            dynamicallyBuildingTargets: Set<Target>,
            diagnostics: [Diagnostic],
            lastAccess: UInt64
        ) {
            self.contentSignature = contentSignature
            self.allTargets = allTargets
            self.targetDependencies = targetDependencies
            self.targetsToLinkedReferencesToProducingTargets =
                targetsToLinkedReferencesToProducingTargets
            self.dynamicallyBuildingTargets = dynamicallyBuildingTargets
            self.diagnostics = diagnostics
            self.lastAccess = lastAccess
        }
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

    /// Scan all cached entries for a content signature match.
    ///
    /// Unlike `lookup(signature:)` which does an exact key lookup,
    /// this scans all entries because the full signature (which
    /// includes workspaceIdentity) will be different even when the
    /// content is identical.
    static func lookupByContentSignature(
        _ contentSig: Int
    ) -> CachedDependencyGraph? {
        entries.withLock { entries in
            for (_, entry) in entries {
                if entry.contentSignature == contentSig {
                    return entry
                }
            }
            return nil
        }
    }

    /// Remap all Target references in a cached graph to point at
    /// fresh objects from the new workspace.
    ///
    /// Returns nil if any cached Target GUID is not found in the new
    /// workspace, which means the PIF structure changed and a full
    /// rebuild is needed.
    package static func remapGraph(
        _ cached: CachedDependencyGraph,
        to workspace: Workspace
    ) -> CachedDependencyGraph? {
        // Build GUID → new Target lookup.
        // If ANY target GUID is missing, bail out.
        var guidToNewTarget: [String: Target] = [:]
        for ct in cached.allTargets {
            let guid = ct.target.guid
            guard let newTarget = workspace.target(for: guid) else {
                return nil
            }
            guidToNewTarget[guid] = newTarget
        }
        for target in cached.dynamicallyBuildingTargets {
            let guid = target.guid
            guard let newTarget = workspace.target(for: guid) else {
                return nil
            }
            guidToNewTarget[guid] = newTarget
        }

        // Remap allTargets
        var newAllTargets = OrderedSet<ConfiguredTarget>()
        for ct in cached.allTargets {
            newAllTargets.append(
                ct.replacingTarget(guidToNewTarget[ct.target.guid]!)
            )
        }

        // Remap targetDependencies
        var newDeps = [ConfiguredTarget:
            [ResolvedTargetDependency]](
            minimumCapacity: cached.targetDependencies.count
        )
        for (ct, deps) in cached.targetDependencies {
            let newCT = ct.replacingTarget(
                guidToNewTarget[ct.target.guid]!
            )
            newDeps[newCT] = deps.map { dep in
                dep.replacingTarget(
                    guidToNewTarget[dep.target.target.guid]!
                )
            }
        }

        // Remap targetsToLinkedReferencesToProducingTargets
        var newLinked = [ConfiguredTarget:
            [BuildFile.BuildableItem: ResolvedTargetDependency]](
            minimumCapacity: cached
                .targetsToLinkedReferencesToProducingTargets.count
        )
        for (ct, innerMap) in cached
            .targetsToLinkedReferencesToProducingTargets
        {
            let newCT = ct.replacingTarget(
                guidToNewTarget[ct.target.guid]!
            )
            var newInner = [BuildFile.BuildableItem:
                ResolvedTargetDependency](
                minimumCapacity: innerMap.count
            )
            for (buildableItem, dep) in innerMap {
                newInner[buildableItem] = dep.replacingTarget(
                    guidToNewTarget[dep.target.target.guid]!
                )
            }
            newLinked[newCT] = newInner
        }

        // Remap dynamicallyBuildingTargets
        let newDynamic = Set(
            cached.dynamicallyBuildingTargets
                .map { guidToNewTarget[$0.guid]! }
        )

        return CachedDependencyGraph(
            contentSignature: cached.contentSignature,
            allTargets: newAllTargets,
            targetDependencies: newDeps,
            targetsToLinkedReferencesToProducingTargets: newLinked,
            dynamicallyBuildingTargets: newDynamic,
            diagnostics: cached.diagnostics,
            lastAccess: nextAccessTime()
        )
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

    /// Compute a content-based cache signature from the same inputs
    /// as `computeSignature`, but **excluding** `workspaceIdentity`.
    ///
    /// When the PIF is re-transferred after a source-only change,
    /// the workspace object identity changes but the content
    /// (workspace signature, build parameters, target GUIDs) stays
    /// the same. A content signature match lets us remap the cached
    /// graph's Target references instead of recomputing the entire
    /// dependency graph.
    static func computeContentSignature(
        workspaceSignature: String,
        buildRequest: BuildRequest,
        purpose: TargetBuildGraph.Purpose
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(workspaceSignature)
        hasher.combine(buildRequest.parameters)
        for targetInfo in buildRequest.buildTargets {
            hasher.combine(targetInfo.target.guid)
            hasher.combine(targetInfo.parameters)
        }
        hasher.combine(buildRequest.useImplicitDependencies)
        hasher.combine(buildRequest.useParallelTargets)
        hasher.combine(buildRequest.skipDependencies)
        hasher.combine(buildRequest.dependencyScope)
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
        hasher.combine(purpose)
        return hasher.finalize()
    }
}
