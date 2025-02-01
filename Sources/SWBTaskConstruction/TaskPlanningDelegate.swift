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

package import SWBUtil
package import SWBCore

/// The task construction protocol is used to interface the BuildSystem (a downstream library) with task planning. This allows the implementations to be private to the BuildSystem and construction is exposed only through this interface.
///
/// If any errors are emitted, the planning process will complete but the client should not make any assumptions about the consistency of the result (in particular, it should not attempt any real build or processing of the results).
package protocol TaskPlanningDelegate: GlobalProductPlanDelegate, TaskPlanningNodeCreationDelegate, ActivityReporter {
    /// Create a task which executes a command.
    func createTask(_ builder: inout PlannedTaskBuilder) -> any PlannedTask

    func recordAttachment(contents: ByteString) -> Path

    /// Create a gate task for use in controlling task ordering.
    ///
    /// Gate tasks don't actually execute any work, but instead are used to realize an ordering constraint between the inputs and the output.
    //
    // FIXME: Eventually, we should investigate whether to just push this concept down into llbuild as a first class feature. That might be simpler, more efficient, and more convenient.
    func createGateTask(_ inputs: [any PlannedNode], output: any PlannedNode, name: String, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) -> any PlannedTask

    var taskActionCreationDelegate: any TaskActionCreationDelegate { get }

    /// The delegate to be able to get information from the client.
    var clientDelegate: any TaskPlanningClientDelegate { get }
}

extension TaskPlanningDelegate {
    package var coreClientDelegate: any CoreClientDelegate {
        clientDelegate
    }
}

/// Protocol to create nodes during task planning.
package protocol TaskPlanningNodeCreationDelegate {
    /// Create a virtual node.
    func createVirtualNode(_ name: String) -> PlannedVirtualNode

    /// Create a node representing a file on the file system.
    ///
    /// - absolutePath: The input path, which must be absolute.
    func createNode(absolutePath path: Path) -> PlannedPathNode

    /// Create a node representing a directory on the file system.
    ///
    /// - absolutePath: The input path, which must be absolute.
    /// - excluding: The fnmatch-style patterns to ignore.
    func createDirectoryTreeNode(absolutePath path: Path, excluding: [String]) -> PlannedDirectoryTreeNode

    /// Create a node representing a top-level directory used by the build.
    ///
    /// This is used for ensuring these directories are only created once across the entire build.
    /// If a node for `path` already exists, the existing instance will be returned.
    ///
    /// - parameter absolutePath: The input path, which must be absolute.
    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode

}

extension TaskPlanningNodeCreationDelegate {
    /// Create a node representing a directory on the file system.
    ///
    /// - absolutePath: The input path, which must be absolute.
    func createDirectoryTreeNode(absolutePath path: Path) -> PlannedDirectoryTreeNode {
        return createDirectoryTreeNode(absolutePath: path, excluding: [])
    }
}

/// The task planning client delegate provides an interface for task planning to get needed information from the client.
package protocol TaskPlanningClientDelegate: CoreClientDelegate {

}
