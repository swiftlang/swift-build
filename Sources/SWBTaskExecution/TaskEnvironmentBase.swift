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

import SWBUtil

/// One of the environments a task store shares among its tasks. A task refers to it and carries only the values that differ.
final class TaskEnvironmentBase: Sendable {
    let keys: [String]
    let values: [String]

    init(keys: [String], values: [String]) {
        self.keys = keys
        self.values = values
    }
}

/// A serializer delegate that lets tasks refer to their task store's environment bases rather than writing their environments in full.
protocol TaskEnvironmentSerializerDelegate: AnyObject, SerializerDelegate {
    var taskEnvironmentBaseTable: EnvironmentBaseTable? { get set }
}

/// The deserializing counterpart of `TaskEnvironmentSerializerDelegate`.
protocol TaskEnvironmentDeserializerDelegate: AnyObject, DeserializerDelegate {
    var taskEnvironmentBases: [TaskEnvironmentBase] { get set }
}

/// The environment of a task whose strings have not been interned.
enum TaskDirectEnvironment {
    case bindings([(String, String)])

    /// The base's bindings with `values` substituted at `positions`, expanded only when asked for.
    case derived(base: TaskEnvironmentBase, positions: [Int], values: [String])

    var bindings: [(String, String)] {
        switch self {
        case .bindings(let bindings):
            return bindings
        case .derived(let base, let positions, let values):
            var merged = base.values
            for (position, value) in zip(positions, values) {
                merged[position] = value
            }
            return Array(zip(base.keys, merged))
        }
    }
}

/// Interned handles for each environment base, computed once per arena.
final class TaskEnvironmentBaseHandleCache {
    private var handlesByBase = [ObjectIdentifier: [(StringArena.Handle, StringArena.Handle)]]()

    func handles(for base: TaskEnvironmentBase, stringArena: StringArena) -> [(StringArena.Handle, StringArena.Handle)] {
        let id = ObjectIdentifier(base)
        if let cached = handlesByBase[id] {
            return cached
        }
        let handles = zip(base.keys, base.values).map { (stringArena.intern($0), stringArena.intern($1)) }
        handlesByBase[id] = handles
        return handles
    }
}
