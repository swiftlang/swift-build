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

/// Container for a list of search paths and methods for finding paths. The requested path will be searched in the search paths
/// in the order they were configured.
public final class StackedSearchPath: Sendable {
    /// The ordered list of search paths.
    public let paths: [Path]

    /// The filesystem to use for lookup queries.
    public let fs: any FSProxy

    /// The cache of names to resolved paths (or nil, for missing entries).
    private let resolvedPaths = Registry<Path, Path?>()

    public init(paths: [Path], fs: any FSProxy) {
        // All input paths should be absolute.
        for path in paths where !path.isAbsolute {
            preconditionFailure("input path must be absolute: '\(path.str)'")
        }
        self.paths = paths
        self.fs = fs
    }

    public init(environment: Environment, fs: any FSProxy) {
        self.paths = environment[.path]?.split(separator: Path.pathEnvironmentSeparator).map(Path.init) ?? []
        self.fs = fs
    }

    /// Find the path corresponding to get the given relative path. If the given path is absolute,
    /// the lookup is a noop.
    public func lookup(_ path: Path) -> Path? {
        // If the path is absolute, we are done.
        if path.isAbsolute {
            return path
        }

        // Otherwise, look up or compute the result.
        return resolvedPaths.getOrInsert(path) {
            // Find the first occurrence of the path relative to the search paths.
            for searchPath in paths {
                let candidate = searchPath.join(path)
                if fs.exists(candidate) {
                    return candidate
                }
            }

            // We didn't find anything.
            return nil
        }
    }

    /// Returns the list of search paths as a single string with each path joined by the platform path list separator character (`:` on Unix, `;` on Windows).
    public var environmentRepresentation: String {
        return paths.map { $0.str }.joined(separator: String(Path.pathEnvironmentSeparator))
    }
}

extension StackedSearchPath {
    public func findExecutable(operatingSystem: OperatingSystem, basename: String) -> Path? {
        lookup(Path(operatingSystem.imageFormat.executableName(basename: basename)))
    }

    public func findLibrary(operatingSystem: OperatingSystem, basename: String) -> Path? {
        lookup(Path("lib\(basename).\(operatingSystem.imageFormat.dynamicLibraryExtension)"))
    }
}
