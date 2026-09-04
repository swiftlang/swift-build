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

/// Rewrites path prefixes, mirroring `llvm::PrefixMapper`.
///
/// This reproduces, in Swift Build, the path canonicalization the compiler and `swift-driver`
/// perform for compilation caching, where real paths are replaced by stable pseudo-paths such as
/// `/^src` so that cache keys don't depend on where the sources live.
///
/// Ordering matters: mappings are applied in order and the first match wins, so `sort()` must be
/// called before mapping to produce the same result the compiler would.
public struct PrefixMapper: Sendable {
    /// A single prefix replacement, rewriting the prefix `from` to `to`.
    public struct Mapping: Sendable, Equatable {
        public let from: Path
        public let to: Path

        public init(from: Path, to: Path) {
            self.from = from
            self.to = to
        }
    }

    /// The mappings, in the order they will be applied.
    public private(set) var mappings: [Mapping]

    public init(mappings: [Mapping] = []) {
        self.mappings = mappings
    }

    public var isEmpty: Bool {
        mappings.isEmpty
    }

    public mutating func add(from: Path, to: Path) {
        mappings.append(Mapping(from: from, to: to))
    }

    /// Order the mappings the way `llvm::PrefixMapper::sort` does, by descending `from`, so a more
    /// specific prefix is preferred over a prefix of itself (`/tmp/tmp` before `/tmp`).
    public mutating func sort() {
        // Sorting descending is sufficient to order any prefix ahead of its own prefixes, because a
        // string always sorts after the strings that are prefixes of it.
        mappings.sort { $0.from.str > $1.from.str }
    }

    /// The receiver, sorted. See `sort()`.
    public func sorted() -> PrefixMapper {
        var copy = self
        copy.sort()
        return copy
    }

    /// Apply the first matching mapping to `path`, or return `path` unchanged if none matches.
    ///
    /// Matching is on whole path components, so `/^src` does not match `/^src-other/file.swift`.
    public func map(_ path: Path) -> Path {
        for mapping in mappings {
            // `relativeSubpath(from:)` matches whole components and returns the empty string for an
            // exact match, covering both of the cases `llvm::PrefixMapper` handles.
            guard let suffix = path.relativeSubpath(from: mapping.from) else { continue }
            return suffix.isEmpty ? mapping.to : mapping.to.join(suffix)
        }
        return path
    }

    /// The inverse mapper, exchanging `from` and `to` in every mapping.
    ///
    /// The result is sorted, because the order that was correct for the forward direction says
    /// nothing about the order the inverse direction needs.
    public func inverted() -> PrefixMapper {
        PrefixMapper(mappings: mappings.map { Mapping(from: $0.to, to: $0.from) }).sorted()
    }
}
