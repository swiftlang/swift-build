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

import Testing
@_spi(Testing) import SWBCore

@Suite fileprivate struct PlatformFilteringTests {

    // MARK: - Empty filter set

    @Test
    func emptyFiltersAlwaysMatch() {
        let context = PlatformFilter(platform: "ios")
        #expect(context.matches([]))
    }

    @Test
    func emptyFiltersMatchWithExcludeContext() {
        let context = PlatformFilter(platform: "ios", exclude: true)
        #expect(context.matches([]))
    }

    // MARK: - Simple inclusion matching

    @Test
    func matchesSamePlatformInclusion() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios")
        ]
        #expect(context.matches(filters))
    }

    @Test
    func doesNotMatchDifferentPlatformInclusion() {
        let context = PlatformFilter(platform: "macos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios")
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func matchesOneOfMultipleInclusionFilters() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "macos"),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func doesNotMatchAnyInclusionFilter() {
        let context = PlatformFilter(platform: "watchos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "macos"),
        ]
        #expect(!context.matches(filters))
    }

    // MARK: - Environment matching

    @Test
    func matchesPlatformAndEnvironment() {
        let context = PlatformFilter(platform: "ios", environment: "macabi")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", environment: "macabi")
        ]
        #expect(context.matches(filters))
    }

    @Test
    func doesNotMatchWhenEnvironmentDiffers() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", environment: "macabi")
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func doesNotMatchWhenPlatformMatchesButEnvironmentDiffers() {
        let context = PlatformFilter(platform: "ios", environment: "simulator")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", environment: "macabi")
        ]
        #expect(!context.matches(filters))
    }

    // MARK: - Exclude context (self.exclude == true)

    @Test
    func excludeContextMatchesWhenPlatformNotInFilters() {
        let context = PlatformFilter(platform: "macos", exclude: true)
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func excludeContextDoesNotMatchWhenPlatformInFilters() {
        let context = PlatformFilter(platform: "ios", exclude: true)
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func excludeContextMatchesWhenEnvironmentDiffers() {
        let context = PlatformFilter(platform: "ios", exclude: true, environment: "macabi")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func excludeContextDoesNotMatchWhenPlatformAndEnvironmentInFilters() {
        let context = PlatformFilter(platform: "ios", exclude: true, environment: "macabi")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", environment: "macabi"),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func excludeContextMatchesWhenNoneOfMultipleFiltersMatch() {
        let context = PlatformFilter(platform: "watchos", exclude: true)
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "macos"),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func excludeContextDoesNotMatchWhenOneOfMultipleFiltersMatches() {
        let context = PlatformFilter(platform: "ios", exclude: true)
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "macos"),
        ]
        #expect(!context.matches(filters))
    }

    // MARK: - Exclusion filters in the filter set

    @Test
    func excludedByExclusionFilter() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func notExcludedWhenExclusionFilterTargetsDifferentPlatform() {
        let context = PlatformFilter(platform: "macos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func onlyExclusionFiltersMatchesNonExcludedPlatform() {
        let context = PlatformFilter(platform: "watchos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true),
            PlatformFilter(platform: "macos", exclude: true),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func onlyExclusionFiltersDoesNotMatchExcludedPlatform() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true),
            PlatformFilter(platform: "macos", exclude: true),
        ]
        #expect(!context.matches(filters))
    }

    // MARK: - Mixed inclusion and exclusion filters

    @Test
    func inclusionMatchButAlsoExcluded() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "macos"),
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func inclusionMatchNotExcluded() {
        let context = PlatformFilter(platform: "macos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "macos"),
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func noInclusionMatchAndNotExcluded() {
        let context = PlatformFilter(platform: "watchos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "macos"),
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(!context.matches(filters))
    }

    // MARK: - Same platform both included and excluded in filter set

    @Test
    func samePlatformIncludedAndExcludedRejectsMatchingContext() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func samePlatformIncludedAndExcludedRejectsNonMatchingContext() {
        let context = PlatformFilter(platform: "macos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func samePlatformIncludedAndExcludedWithExcludeContext() {
        let context = PlatformFilter(platform: "ios", exclude: true)
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func samePlatformIncludedAndExcludedOtherPlatformMatches() {
        let context = PlatformFilter(platform: "macos")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
            PlatformFilter(platform: "ios", exclude: true),
            PlatformFilter(platform: "macos"),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func samePlatformIncludedAndExcludedWithEnvironment() {
        let context = PlatformFilter(platform: "ios", environment: "macabi")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", environment: "macabi"),
            PlatformFilter(platform: "ios", exclude: true, environment: "macabi"),
        ]
        #expect(!context.matches(filters))
    }

    // MARK: - Exclude context against exclusion filters

    @Test
    func excludeContextAgainstExclusionFilterSamePlatform() {
        let context = PlatformFilter(platform: "ios", exclude: true)
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func excludeContextAgainstExclusionFilterDifferentPlatform() {
        let context = PlatformFilter(platform: "macos", exclude: true)
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true),
        ]
        #expect(context.matches(filters))
    }

    // MARK: - Exclusion filter with environment in the filter set

    @Test
    func excludedByEnvironmentSpecificExclusionFilter() {
        let context = PlatformFilter(platform: "ios", environment: "macabi")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true, environment: "macabi"),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func notExcludedWhenExclusionFilterEnvironmentDiffers() {
        let context = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios", exclude: true, environment: "macabi"),
        ]
        #expect(context.matches(filters))
    }

    // MARK: - Optional PlatformFilter matching

    @Test
    func nilContextMatchesEmptyFilters() {
        let context: PlatformFilter? = nil
        #expect(context.matches([]))
    }

    @Test
    func nilContextDoesNotMatchNonEmptyFilters() {
        let context: PlatformFilter? = nil
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func someContextDelegatesToWrappedValue() {
        let context: PlatformFilter? = PlatformFilter(platform: "ios")
        let filters: Set<PlatformFilter> = [
            PlatformFilter(platform: "ios"),
        ]
        #expect(context.matches(filters))
    }
}
