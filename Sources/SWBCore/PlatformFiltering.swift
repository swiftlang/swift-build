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

public import SWBMacro
import SWBUtil

extension PlatformFilter {
    public convenience init?(_ scope: MacroEvaluationScope) {
        let platformName = scope.evaluate(BuiltinMacros.PLATFORM_NAME)
        let os = (!scope.evaluate(BuiltinMacros.__USE_PLATFORM_NAME_FOR_FILTERS) ? scope.evaluate(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX).nilIfEmpty : nil) ?? platformName

        // We always want developers to set platform filters for a device platform *and* its simulator counterpart as a *single* inseparable unit.
        // To implicitly enforce this behavior (and avoid the need for Swift Build clients to replicate it individually) for any target platform
        // whose *environment* is "simulator" we simply omit it, effectively treating the target the same as the corresponding device platform.
        let targetTripleSuffix = scope.evaluate(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX)
        let env = targetTripleSuffix == "-simulator" ? "" : targetTripleSuffix

        guard env.isEmpty || env.hasPrefix("-") else {
            // If LLVM_TARGET_TRIPLE_SUFFIX is set, it *must* begin with a dash.
            // However, let's not crash release builds if this is ever the case.
            assertionFailure("Unexpected value for LLVM_TARGET_TRIPLE_SUFFIX: \(env)")
            return nil
        }

        self.init(platform: os, environment: !env.isEmpty ? env.withoutPrefix("-") : env)
    }

    public func matches(_ filters: Set<PlatformFilter>) -> Bool {
        // Filters are ignored if none are set.
        // Since there is assumed to be no value in the empty set having the meaning of filtering everything out, the empty set means not to filter at all.
        if filters.isEmpty {
            return true
        }

        // Otherwise, we check if the current build context is compatible with the filter.
        return filters.contains(self)
    }
}

extension Optional: PlatformFilteringContext where Wrapped == PlatformFilter {
    public func matches(_ filters: Set<PlatformFilter>) -> Bool {
        // Convenience for Optionals: if no filter was computed for the current context (this shouldn't really happen),
        // that does NOT match any filters, if there are filters set.
        return map { $0.matches(filters) } ?? filters.isEmpty
    }

    public var currentPlatformFilter: PlatformFilter? {
        return self
    }
}

public protocol PlatformFilteringContext {
    /// Platform filter representative of the current build context, used for filtering.
    var currentPlatformFilter: PlatformFilter? { get }
}

extension PlatformFilter: PlatformFilteringContext {
    public var currentPlatformFilter: PlatformFilter? {
        return self
    }
}
