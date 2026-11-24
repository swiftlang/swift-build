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

import Synchronization

/// The directories whose listing changed since the previous build, to report to a dependency scanner.
///
/// A scanner records only the top directory of a tree it depends on, so a change anywhere in a tree has to be reported as a change to the directory and each of its ancestors. All members can be called from any thread.
public final class InvalidatedPathSet: Sendable {
    private let paths = SWBMutex<Set<String>>([])

    public init() {}

    /// Every path reported so far.
    public var allPaths: [String] {
        paths.withLock { Array($0) }
    }

    /// Records `directory` and its ancestors.
    ///
    /// - returns: The paths which hadn't been recorded before.
    public func insert(directory: Path) -> [String] {
        paths.withLock { paths in
            var newPaths: [String] = []
            var current = directory
            // If a path is already recorded, so are its ancestors.
            while paths.insert(current.str).inserted {
                newPaths.append(current.str)
                let parent = current.dirname
                if parent == current {
                    break
                }
                current = parent
            }
            return newPaths
        }
    }
}
