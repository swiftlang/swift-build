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

package import SWBUtil
import Synchronization

/// Collects the set of Windows DLL copy operations needed across all targets in the workspace.
///
/// During the planning phase, `WindowsDLLCopyTaskProducer` iterates target contexts sequentially
/// and calls `register(sourcePath:destinationPath:)` for each DLL variant that matches a target's
/// triple. Because processing is sequential, the first target to register a given destination
/// path always wins — providing deterministic task generation regardless of how many targets
/// transitively reference the same artifact bundle.
package final class WindowsDLLCopyContext: Sendable {
    package struct CopyRequirement: Hashable, Sendable {
        /// Absolute path to the DLL inside the artifact bundle.
        package let sourcePath: Path
        /// Destination path: `$(TARGET_BUILD_DIR)/dllname.dll`.
        package let destinationPath: Path
    }

    private struct State: Sendable {
        var requirements: [Path: CopyRequirement] = [:]
        var frozen = false
    }

    private let state = SWBMutex(State())

    package init() {}

    /// Register a DLL copy requirement. The first call for a given `destinationPath` wins;
    /// subsequent calls for the same destination are silently ignored.
    func register(sourcePath: Path, destinationPath: Path) {
        state.withLock { s in
            precondition(!s.frozen)
            if s.requirements[destinationPath] == nil {
                s.requirements[destinationPath] = CopyRequirement(sourcePath: sourcePath, destinationPath: destinationPath)
            }
        }
    }

    func freeze() {
        state.withLock { $0.frozen = true }
    }

    var copyRequirements: [CopyRequirement] {
        state.withLock { s in
            precondition(s.frozen)
            return Array(s.requirements.values)
        }
    }
}
