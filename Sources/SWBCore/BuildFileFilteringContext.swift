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

public import SWBUtil

public protocol BuildFileFilteringContext: PlatformFilteringContext {
    var excludedSourceFileNames: [String] { get }
    var includedSourceFileNames: [String] { get }
}

/// Indicates whether a file was excluded in the current build context.
public enum BuildFileFilterState {
    /// The file was NOT excluded.
    case included

    /// The file was excluded due to a platform filter or the `EXCLUDED_SOURCE_FILE_NAMES` build setting.
    case excluded(BuildFileExclusionReason)
}

/// The reason _why_ a file was excluded in the current build context.
public enum BuildFileExclusionReason {
    /// The file was excluded because its platform filters did not match that of the current build context.
    case platformFilter

    /// The file was excluded due to a pattern in the `EXCLUDED_SOURCE_FILE_NAMES` build setting.
    case patternLists(excludePattern: String)
}

extension BuildFileFilteringContext {
    /// Returns the filter state of `path`, indicating whether it should be included or excluded from the build phase based on the build settings.  A file is excluded if it is in the exclusion list and not in the inclusion list, or there are exclusion filters set on the build file and the current build context does not match said filters.
    public func filterState(of path: Path, filters: Set<PlatformFilter>) -> BuildFileFilterState {
        if !currentPlatformFilter.matches(filters) {
            return .excluded(.platformFilter)
        }

        guard let excludePattern = path.firstMatchingPatternInFilenamePatternList(excludedSourceFileNames), !path.isInFilenamePatternList(includedSourceFileNames) else {
            return .included
        }

        return .excluded(.patternLists(excludePattern: excludePattern))
    }

    /// Returns whether `path` should be excluded from the build phase based on the build settings.  See `filterState(of:filters)` for details.
    public func isExcluded(_ path: Path, filters: Set<PlatformFilter>) -> Bool {
        switch filterState(of: path, filters: filters) {
        case .excluded:
            return true
        case .included:
            return false
        }
    }
}

public protocol PathResolvingBuildFileFilteringContext: BuildFileFilteringContext {
    var filePathResolver: FilePathResolver { get }
}

extension PathResolvingBuildFileFilteringContext {
    public func isExcluded(header: TargetHeaderInfo.Entry) -> Bool {
        return path(header: header) == nil
    }

    /// Returns the resolved absolute path of the header entry, or `nil` if the file is excluded by platform filters.
    public func path(header: TargetHeaderInfo.Entry) -> Path? {
        let path = filePathResolver.resolveAbsolutePath(header.fileReference)
        if isExcluded(path, filters: header.platformFilters) {
            return nil
        }
        return path
    }
}
