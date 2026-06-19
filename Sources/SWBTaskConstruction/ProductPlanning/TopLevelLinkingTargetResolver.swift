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

package import SWBCore

package final class TopLevelLinkingTargetResolver {
    /// Key is a target; value is the set of targets that directly use that target.
    private let reverseDirectDependenciesByTarget: [ConfiguredTarget: Set<ConfiguredTarget>]
    /// Targets that are known to be top-level linking targets from build settings.
    private let topLevelLinkingTargets: Set<ConfiguredTarget>
    /// Determines if a target is dynamically building during diamond resolution.
    private let isDynamicallyBuildingTarget: (ConfiguredTarget) -> Bool
    /// Reuse previously computed top-level linking targets for already visited targets.
    private var memo = [ConfiguredTarget: Set<ConfiguredTarget>]()
    /// Records the targets on the current recursion path to detect cycles and avoid infinite recursion.
    private var visiting = Set<ConfiguredTarget>()

    package init(
        reverseDirectDependenciesByTarget: [ConfiguredTarget: Set<ConfiguredTarget>],
        topLevelLinkingTargets: Set<ConfiguredTarget>,
        isDynamicallyBuildingTarget: @escaping (ConfiguredTarget) -> Bool
    ) {
        self.reverseDirectDependenciesByTarget = reverseDirectDependenciesByTarget
        self.topLevelLinkingTargets = topLevelLinkingTargets
        self.isDynamicallyBuildingTarget = isDynamicallyBuildingTarget
    }

    package func resolve(
        for configuredTarget: ConfiguredTarget
    ) -> Set<ConfiguredTarget> {
        resolveTracking(for: configuredTarget).targets
    }

    /// Walks the reverse dependencies from `configuredTarget`
    /// and returns the top-level linking targets reachable from it.
    ///
    /// - Parameter configuredTarget: The target to start the reverse traversal from.
    /// - Returns: `targets` is the set of top-level linking targets reachable from `configuredTarget`.
    ///   `truncated` indicates whether this result was computed by truncating a dependency cycle.
    ///   When `truncated` is `true`, the result may be incomplete, so it is not cached.
    private func resolveTracking(
        for configuredTarget: ConfiguredTarget
    ) -> (targets: Set<ConfiguredTarget>, truncated: Bool) {
        if let cached = memo[configuredTarget] {
            return (cached, false)
        }

        guard visiting.insert(configuredTarget).inserted else {
            return ([], true)
        }
        defer {
            visiting.remove(configuredTarget)
        }

        var topLevelTargets = Set<ConfiguredTarget>()
        var truncated = false
        for linkingTarget in reverseDirectDependenciesByTarget[configuredTarget] ?? [] {
            if topLevelLinkingTargets.contains(linkingTarget)
                || isDynamicallyBuildingTarget(linkingTarget) {
                topLevelTargets.insert(linkingTarget)
            } else {
                let resolved = resolveTracking(for: linkingTarget)
                topLevelTargets.formUnion(resolved.targets)
                truncated = truncated || resolved.truncated
            }
        }
        // Cache only complete results.
        if !truncated {
            memo[configuredTarget] = topLevelTargets
        }
        return (topLevelTargets, truncated)
    }
}
