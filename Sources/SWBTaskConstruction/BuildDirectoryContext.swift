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
import Synchronization

/// Tracks the build directory creation usage across the build plan. This allows the usage information to be cached during task planning.
final class BuildDirectoryContext: Sendable {
    private struct State {
        var isFrozen = false
        var _paths = Set<Path>()
    }

    private let state = SWBMutex<State>(.init())

    /// Adds the path of a build directory that will be created.
    /// - Remark: This must be called *only* from the `.planning` phase.
    func add(_ paths: [Path]) {
        state.withLock { state in
            precondition(!state.isFrozen)
            state._paths.formUnion(paths)
        }
    }

    /// The build directories whose creation is depended on throughout the workspace.
    /// - Remark: This must only be used during the `.taskGeneration` phase, where `paths` should no longer be changing.
    var paths: Set<Path> {
        return state.withLock { state in
            precondition(state.isFrozen)
            return state._paths
        }
    }

    func freeze() {
        return state.withLock { state in
            precondition(!state.isFrozen)
            state.isFrozen = true
        }
    }
}
