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

public import SWBMacro
import SWBUtil

extension BuildConfigurationFilter {
    public convenience init?(_ scope: MacroEvaluationScope) {
        let buildConfiguration = scope.evaluate(BuiltinMacros.CONFIGURATION)
        self.init(buildConfiguration: buildConfiguration)
    }

    public func matches(_ filters: Set<BuildConfigurationFilter>) -> Bool {
        // Filters are ignored if none are set.
        // Since there is assumed to be no value in the empty set having the meaning of filtering everything out, the empty set means not to filter at all.
        if filters.isEmpty {
            return true
        }

        // Otherwise, we check if the current build context is compatible with the filter.
        return filters.contains(self)
    }
}

extension Optional: BuildConfigurationFilteringContext where Wrapped == BuildConfigurationFilter {
    public func matches(_ filters: Set<BuildConfigurationFilter>) -> Bool {
        // Convenience for Optionals: if no filter was computed for the current context (this shouldn't really happen),
        // that does NOT match any filters, if there are filters set.
        return map { $0.matches(filters) } ?? filters.isEmpty
    }

    public var currentBuildConfigurationFilter: BuildConfigurationFilter? {
        return self
    }
}

public protocol BuildConfigurationFilteringContext {
    /// Build configuration filter representative of the current build context, used for filtering.
    var currentBuildConfigurationFilter: BuildConfigurationFilter? { get }
}

extension BuildConfigurationFilter: BuildConfigurationFilteringContext {
    public var currentBuildConfigurationFilter: BuildConfigurationFilter? {
        return self
    }
}
