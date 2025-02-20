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

/// A node that represents an input or output of a task (often, but not necessarily, representing the path of a file system entity).  Every node has a name, even if it doesn’t have a path.  If it does have a path, the name will be the same as the last path component of a path.
/// PlannedNode are AnyObject-type and all instances are interned to allow for reference equality.
public protocol PlannedNode: AnyObject, Sendable, CustomStringConvertible {
    /// Node name (never empty, and constant through the lifetime of the node).
    var name: String { get }

    /// Path of the file represented by the node.
    // FIXME: This should actually only be relevant for PlannedPathNodes, but that will require a lot of adjusting of callers.
    var path: Path { get }
}

/// A node that represents the path of a file system entity.
public final class PlannedPathNode: PlannedNode {
    public let name: String
    public let path: Path

    fileprivate init(_ path: Path) {
        assert(path.normalize() == path)
        self.path = path
        self.name = path.basename
    }

    public var description: String {
        return "<\(type(of: self)):\(path.str)>"
    }
}

/// A node that represents a directory *tree* as a file system entity.
///
/// The distinction between this and `PlannedPathNode` is that the directory node represents the recursive contents of the entire directory, not just the file at the specific path.
public final class PlannedDirectoryTreeNode: PlannedNode {
    public let name: String
    public let path: Path

    /// The set of patterns to exclude from the directory.
    public let exclusionPatterns: [String]

    fileprivate init(_ path: Path, excluding: [String] = []) {
        assert(path.normalize() == path)
        self.path = path
        self.name = path.basename + "/"
        self.exclusionPatterns = excluding
    }

    public var description: String {
        return "<\(type(of: self)):\(path.str)>"
    }
}

/// A node that represents a conceptual entity that is not a path.
public final class PlannedVirtualNode: PlannedNode {
    public let name: String
    public let path = Path("")

    fileprivate init(name: String) {
        assert(!name.isEmpty)
        self.name = name
    }

    public var description: String {
        return "<\(type(of: self)):\(name)>"
    }
}

// Intern planned nodes to allow for reference equality
private enum PlannedNodeInternKey: Hashable {
    case path(Path)
    case dir(Path, excluding: [String])
    case virtual(name: String)
}

// TODO: this should really be some kind of weak map or its lifetime scoped to a build description
private let internedPlannedNodes = Registry<PlannedNodeInternKey, any PlannedNode>()

/// Returns a node representing `path`.
/// Interned to allow for reference equality.
public func MakePlannedPathNode(_ path: Path) -> PlannedPathNode {
    let p = path.normalize()
    return internedPlannedNodes.getOrInsert(.path(p)) {
        PlannedPathNode(p)
    } as! PlannedPathNode
}

/// Create a new node representing the *directory* at `path`.
/// Interned to allow for reference equality.
public func MakePlannedDirectoryTreeNode(_ path: Path, excluding: [String] = []) -> PlannedDirectoryTreeNode {
    let p = path.normalize()
    return internedPlannedNodes.getOrInsert(.dir(p, excluding: excluding)) {
        PlannedDirectoryTreeNode(p, excluding: excluding)
    } as! PlannedDirectoryTreeNode
}

/// Create a new virtual node named `name` (which must be a non-empty string).
/// Interned to allow for reference equality.
public func MakePlannedVirtualNode(_ name: String) -> PlannedVirtualNode {
    return internedPlannedNodes.getOrInsert(.virtual(name: name)) {
        PlannedVirtualNode(name: name)
    } as! PlannedVirtualNode
}
