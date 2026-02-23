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

import SWBUtil
import Foundation

/// Process-level cache for computed target build graphs.
///
/// Xcode issues multiple `TargetBuildGraph` requests per build action
/// with different parameters (e.g. dependency graph vs actual build,
/// index preparation vs normal build). A multi-entry cache ensures
/// these don't evict each other.
///
/// The cache is static (process-level) because `WorkspaceContext` is
/// recreated on every PIF transfer, even when nothing has changed.
public enum TargetBuildGraphCache {
    /// The data we cache — everything needed by the
    /// `TargetBuildGraph` memberwise init except the live context
    /// objects (workspaceContext, buildRequest, buildRequestContext).
    struct CachedTopology: @unchecked Sendable {
        let allTargets: OrderedSet<ConfiguredTarget>
        let targetDependencies:
            [ConfiguredTarget: [ResolvedTargetDependency]]
        let targetsToLinkedReferencesToProducingTargets:
            [ConfiguredTarget:
                [BuildFile.BuildableItem: ResolvedTargetDependency]]
        let dynamicallyBuildingTargets: Set<Target>
    }

    /// Maximum number of cached entries. Xcode typically issues 2-4
    /// distinct graph requests per build action; 8 gives headroom.
    private static let maxEntries = 8

    private static let _entries =
        SWBMutex<[Int: CachedTopology]>([:])

    /// Look up a cached topology by signature.
    static func lookup(signature: Int) -> CachedTopology? {
        _entries.withLock { entries in
            entries[signature]
        }
    }

    /// Store a computed topology for the given signature.
    static func store(signature: Int, topology: CachedTopology) {
        _entries.withLock { entries in
            // Evict all entries if we exceed the limit (simple reset
            // policy). This only happens when the PIF changes or the
            // user switches between different build configurations.
            if entries.count >= maxEntries {
                entries.removeAll()
            }
            entries[signature] = topology
        }
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
        buildRequest: BuildRequest,
        purpose: TargetBuildGraph.Purpose
    ) -> Int {
        var hasher = Hasher()

        // Normalized PIF signature (strip volatile subobject GUIDs)
        if let range = workspaceSignature.range(
            of: "_subobjects="
        ) {
            hasher.combine(
                workspaceSignature[..<range.lowerBound])
        } else {
            hasher.combine(workspaceSignature)
        }

        // Global build parameters
        hasher.combine(buildRequest.parameters)

        // Top-level build targets and their per-target parameters.
        // Sort by target GUID for order independence.
        for targetInfo in buildRequest.buildTargets.sorted(
            by: { $0.target.guid < $1.target.guid }
        ) {
            hasher.combine(targetInfo.target.guid)
            hasher.combine(targetInfo.parameters)
        }

        // Flags that affect graph topology
        hasher.combine(buildRequest.useImplicitDependencies)
        hasher.combine(buildRequest.useParallelTargets)
        hasher.combine(buildRequest.skipDependencies)

        // Dependency scope affects pruning
        switch buildRequest.dependencyScope {
        case .workspace:
            hasher.combine(0)
        case .buildRequest:
            hasher.combine(1)
        }

        // Build command affects the early-return for
        // assembly/preprocessor
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
        switch purpose {
        case .build:
            hasher.combine("build")
        case .dependencyGraph:
            hasher.combine("depgraph")
        }

        return hasher.finalize()
    }
}
