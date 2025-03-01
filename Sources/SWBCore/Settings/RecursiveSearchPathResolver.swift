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

import SWBLibc
public import SWBUtil

/// Resolve recursive search paths to expanded lists.
///
/// The resolver will automatically maintain a cache of all resolved requests made to it. This cache is *not* invalidated with respect to changes in the underlying file system, it is the clients responsibility to create a new resolver if the file system may have changed.
///
/// This class is thread-safe.
public final class RecursiveSearchPathResolver: Sendable {
    /// A container for a recursive search path request.
    public struct Request: Hashable, Comparable, Serializable, Sendable {
        /// The path to expand.
        public let path: Path

        /// The path to return results relative to.
        public let sourcePath: Path

        /// The list of fnmatch() patterns to exclude, if provided.
        public let excludedPatterns: [String]?

        /// The list of fnmatch() patterns to include, if provided.
        public let includedPatterns: [String]?

        public init(path: Path, sourcePath: Path, excludedPatterns: [String]?, includedPatterns: [String]?) {
            self.path = path
            self.sourcePath = sourcePath
            self.excludedPatterns = excludedPatterns
            self.includedPatterns = includedPatterns
        }
        public static func <(lhs: Request, rhs: Request) -> Bool {
            if lhs.path != rhs.path { return lhs.path.str < rhs.path.str }
            if lhs.sourcePath != rhs.sourcePath { return lhs.sourcePath.str < rhs.sourcePath.str }
            if lhs.excludedPatterns != rhs.excludedPatterns { return lhs.excludedPatterns < rhs.excludedPatterns }
            if lhs.includedPatterns != rhs.includedPatterns { return lhs.includedPatterns < rhs.includedPatterns }
            return false
        }

        // MARK: Serialization

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.beginAggregate(4)
            serializer.serialize(path)
            serializer.serialize(sourcePath)
            serializer.serialize(excludedPatterns)
            serializer.serialize(includedPatterns)
            serializer.endAggregate()
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(4)
            self.path = try deserializer.deserialize()
            self.sourcePath = try deserializer.deserialize()
            self.excludedPatterns = try deserializer.deserialize()
            self.includedPatterns = try deserializer.deserialize()
        }
    }

    /// A container for the result of a recursive search path request.
    public struct Result: Equatable, Serializable, Sendable {
        /// The list of resulting paths.
        public let paths: [Path]

        /// The list of warnings generated during expansion.
        public let warnings: [String]

        public init(paths: [Path], warnings: [String]) {
            self.paths = paths
            self.warnings = warnings
        }

        public static func ==(lhs: Result, rhs: Result) -> Bool {
            return lhs.paths == rhs.paths && lhs.warnings == rhs.warnings
        }

        // MARK: Serialization

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.beginAggregate(2)
            serializer.serialize(paths)
            serializer.serialize(warnings)
            serializer.endAggregate()
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            self.paths = try deserializer.deserialize()
            self.warnings = try deserializer.deserialize()
        }
    }

    /// A cached request and result.
    public struct CachedResult: Serializable, Sendable {
        /// The request the result is for.
        public let request: Request

        /// The result.
        public let result: Result

        public init(request: Request, result: Result) {
            self.request = request
            self.result = result
        }

        // MARK: Serialization

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.beginAggregate(2)
            serializer.serialize(request)
            serializer.serialize(result)
            serializer.endAggregate()
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            self.request = try deserializer.deserialize()
            self.result = try deserializer.deserialize()
        }
    }

    /// The maximum number of arguments to generate.
    ///
    /// This is arbitrary, and just to limit the traversal in corner cases.
    public static let maximumNumberOfEntries = 1024

    /// The file system the resolver uses.
    public let fs: any FSProxy

    /// The cache of recursive search path requests.
    private let requestCache = Registry<Request, Result>()

    /// Create a new resolver.
    public init(fs: any FSProxy) {
        self.fs = fs
    }

    /// The canonical list of cached results.
    public var allResults: [CachedResult] {
        return requestCache.keys.sorted().map{ CachedResult(request: $0, result: requestCache[$0]!) }
    }

    /// Expand a recursive search path.
    ///
    /// The result is a set of paths (relative to the `sourcePath`, where possible) of subdirectories of the input path.
    ///
    /// - Parameters:
    ///   - path: The path to search for expanded paths.
    ///   - sourcePath: Results under this path will be returned as a path relative to it, instead of an absolute path.
    ///   - excludedPatterns: If provided, a list of fnmatch() patterns to specify paths to explicitly exclude.
    ///   - includedPatterns: If provided, a list of fnmatch() patterns to specify paths to explicitly include.
    public func expandedPaths(for path: Path, relativeTo sourcePath: Path, excludedPatterns: [String]? = nil, includedPatterns: [String]? = nil) -> (paths: [Path], warnings: [String]) {
        let result = expandedPaths(for: Request(path: path, sourcePath: sourcePath, excludedPatterns: excludedPatterns, includedPatterns: includedPatterns))
        return (result.paths, result.warnings)
    }

    public func expandedPaths(for request: Request) -> Result {
        return requestCache.getOrInsert(request) { computeExpandedPaths(for: request) }
    }

    private func computeExpandedPaths(for request: Request) -> Result {
        /// Check if a string matches a pattern list.
        ///
        /// - Returns: True if any pattern in the list matches the input string.
        func matches(_ value: String, patterns: [String]?) -> Bool {
            if let patterns {
                for pattern in patterns {
                    do {
                        if try fnmatch(pattern: pattern, input: value, options: .pathname) {
                            return true
                        }
                    } catch {
                    }
                }
            }
            return false
        }
        let sourcePath = request.sourcePath
        var worklist = Queue<Path>()

        // Only expand the directory if it exists.
        if fs.exists(request.path) {
            worklist.append(request.path)
        }

        // Perform a breadth-first expansion of the search paths.
        var result: [Path] = []
        var warnings: [String] = []
        while let path = worklist.popFirst() {
            // Add the path to the result.
            if path == sourcePath {
                result.append(Path("."))
            } else if sourcePath.isRoot {
                result.append(Path(String(path.str[path.str.utf8.index(after: path.str.utf8.startIndex)...])))
            } else if path.str.hasPrefix(sourcePath.str) && Path.pathSeparatorsUTF8.contains(path.str.utf8[path.str.utf8.index(path.str.utf8.startIndex, offsetBy: sourcePath.str.utf8.count)]) {
                // FIXME: Use dropFirst() once available everywhere.
                result.append(Path(String(path.str[path.str.utf8.index(path.str.utf8.startIndex, offsetBy: sourcePath.str.utf8.count + 1)...])))
            } else {
                result.append(path)
            }

            // Stop the search if we have reached the limit.
            if result.count == RecursiveSearchPathResolver.maximumNumberOfEntries {
                warnings.append("recursive header search expansion aborted (reached maximum limit)")
                break
            }

            // Determine the children to visit.
            let childNames: [String]
            do {
                childNames = try fs.listdir(path)
            } catch {
                // Currently we simply ignore any errors during recursive expansion.
                warnings.append("unable to expand children of '\(path.str)'")
                continue
            }

            let children = childNames.compactMap { child -> Path? in
                // Honor excluded and included pattern lists.
                if matches(child, patterns: request.excludedPatterns) && !matches(child, patterns: request.includedPatterns) {
                    return nil
                }

                // Check if the child is a directory.
                //
                // FIXME: Should we support visiting symlinks optionally?
                let childPath = path.join(child)
                let childInfo: FileInfo
                do {
                    childInfo = try fs.getFileInfo(childPath)
                } catch {
                    warnings.append("unable to get file information for '\(childPath.str)")
                    return nil
                }
                if !childInfo.isDirectory {
                    return nil
                }

                return childPath
            }

            // Enqueue the children.
            for child in children.sorted(by: \.str) {
                worklist.append(child)
            }
        }

        return Result(paths: result, warnings: warnings)
    }
}

private func <(lhs: [String]?, rhs: [String]?) -> Bool {
    switch (lhs, rhs) {
    case (let lhs?, let rhs?):
        return lhs.lexicographicallyPrecedes(rhs)
    case (nil, _?):
        return true
    case (_?, nil):
        return false
    case (nil, nil):
        return false
    }
}
