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

/// Compute the minimum distance from a source node to a destination in a graph.
///
/// This implementation is suitable for individual queries between two (close) nodes in a graph, but is sub-optimal for repeated numbers of queries in large graph.
///
/// - Returns: The distance (in number of edges) of the shortest path from the source to the destination, or nil if there is no such path.
public func minimumDistance<T: Hashable>(
    from source: T, to destination: T, successors: (T) throws -> [T]
) rethrows -> Int? {
    var queue = Queue([(distance: 0, source)])
    var visited = Set([source])

    while let (distance, node) = queue.popFirst() {
        // If this is the destination, we are done.
        if node == destination {
            return distance
        }

        // Otherwise, visit all of the successors in BFS order.
        let succs = try successors(node)
        for succ in succs {
            // If we have already seen this node, we don't need to traverse it.
            if !visited.insert(succ).inserted {
                continue
            }

            queue.append((distance: distance + 1, succ))
        }
    }

    return nil
}

/// Compute the shortest path from a source node to a destination in a graph.
///
/// This implementation is suitable for individual queries between two (close) nodes in a graph, but is sub-optimal for repeated numbers of queries in large graph.
///
/// - Returns: The shortest path (starting with the source and ending with the destination), or nil if there is no such path.
public func shortestPath<T: Hashable>(
    from source: T, to destination: T, successors: (T) throws -> [T]
) rethrows -> [T]? {
    var queue = Queue([[source]])
    var visited = Set([source])

    while let path = queue.popFirst() {
        // If the path ends at the destination, we are done.
        let node = path.last!
        if node == destination {
            return path
        }

        // Otherwise, visit all of the successors in BFS order.
        for succ in try successors(node) {
            // If we have already seen this node, we don't need to traverse it.
            if !visited.insert(succ).inserted {
                continue
            }

            queue.append(path + [succ])
        }
    }

    return nil
}

/// Compute the transitive closure of an input node set.
///
/// - Note: The relation is *not* assumed to be reflexive; i.e. the result will
///         not automatically include `nodes` unless present in the relation defined by
///         `successors`.
public func transitiveClosure<T>(
    _ nodes: [T], successors: (T) throws -> [T]
    ) rethrows -> (result: OrderedSet<T>, dupes: OrderedSet<T>) {
    var dupes = OrderedSet<T>()
    var result = OrderedSet<T>()

    // The queue of items to recursively visit.
    //
    // We add items post-collation to avoid unnecessary queue operations.
    var queue = nodes
    while let node = queue.popLast() {
        for succ in try successors(node) {
            if result.append(succ).inserted {
                queue.append(succ)
            } else {
                dupes.append(succ)
            }
        }
    }

    return (result, dupes)
}
