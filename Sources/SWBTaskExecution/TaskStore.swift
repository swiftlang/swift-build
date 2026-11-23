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

package import SWBCore
package import SWBUtil
import Synchronization

package final class TaskStore {
    package enum Error: Swift.Error {
        case duplicateTaskIdentifier
    }

    private var tasks: [TaskIdentifier: (Task, Task.Storage.InternedStorage.Handles)]
    private let stringArena = StringArena()
    private let byteStringArena = ByteStringArena()

    init() {
        tasks = [:]
    }

    package func insertTask(_ task: Task) throws -> TaskIdentifier {
        let id = task.identifier
        guard !tasks.keys.contains(id) else {
            throw Error.duplicateTaskIdentifier
        }
        tasks[id] = (task, task.internedStorage(byteStringArena: byteStringArena, stringArena: stringArena))
        return id
    }

    func freeze() -> FrozenTaskStore {
        let frozenStringArena = stringArena.freeze()
        let frozenByteStringArena = byteStringArena.freeze()
        let internedTasks = self.tasks.mapValues { taskAndStorage in
            Task(task: taskAndStorage.0, internedStorageHandles: taskAndStorage.1, frozenByteStringArena: frozenByteStringArena, frozenStringArena: frozenStringArena)
        }
        return FrozenTaskStore(tasks: internedTasks, stringArena: frozenStringArena, byteStringArena: frozenByteStringArena)
    }
}

// TaskStore is not Sendable
@available(*, unavailable) extension TaskStore: Sendable {}

package final class FrozenTaskStore: Sendable {
    fileprivate init(tasks: [TaskIdentifier : Task], stringArena: FrozenStringArena, byteStringArena: FrozenByteStringArena) {
        self.tasks = tasks
        self.stringArena = stringArena
        self.byteStringArena = byteStringArena
    }

    private let tasks: [TaskIdentifier: Task]
    private let stringArena: FrozenStringArena
    private let byteStringArena: FrozenByteStringArena

    package var taskCount: Int {
        tasks.count
    }

    package func forEachTask(_ perform: (Task) -> Void) {
        for task in tasks.values {
            perform(task)
        }
    }

    package func task(for identifier: TaskIdentifier) -> Task? {
        tasks[identifier]
    }

    package func taskAction(for identifier: TaskIdentifier) -> TaskAction? {
        tasks[identifier]?.action
    }

    /// It is beneficial for the performance of the index queries to have a mapping of tasks in each target.
    /// But since this is not broadly useful we only populate this lazily, on demand. This info is not serialized to the build description.
    private let tasksByTargetCache: SWBMutex<[ConfiguredTarget?: [Task]]> = .init([:])

    /// The tasks associated with a particular target.
    package func tasksForTarget(_ target: ConfiguredTarget?) -> [Task] {
        return tasksByTargetCache.withLock { tasksByTarget in
            tasksByTarget.getOrInsert(target) { tasks.values.filter { $0.forTarget == target } }
        }
    }
}

/// A serializer delegate that lets tasks refer to their task store's arenas and environment bases rather than writing their strings in full.
protocol TaskStoreSerializerDelegate: AnyObject, SerializerDelegate {
    var taskEnvironmentBaseTable: EnvironmentBaseTable? { get set }
    /// The arenas the task store writes ahead of its tasks, which the tasks' strings are handles into.
    var taskStoreArenas: (strings: FrozenStringArena, byteStrings: FrozenByteStringArena)? { get set }
}

/// The deserializing counterpart of `TaskStoreSerializerDelegate`.
protocol TaskStoreDeserializerDelegate: AnyObject, DeserializerDelegate {
    /// The task store's arenas, when its tasks are written as handles into them.
    var taskStoreArenas: (strings: FrozenStringArena, byteStrings: FrozenByteStringArena)? { get set }
    var taskEnvironmentBaseHandles: [[(StringArena.Handle, StringArena.Handle)]] { get set }
}

extension FrozenTaskStore: Serializable {
    package func serialize<T>(to serializer: T) where T : Serializer {
        // The store is written as [strings, byte strings, base keys, base values, tasks]. Tasks refer to the arenas'
        // strings by handle, and the environment bases are read before the tasks that refer to them.
        guard let delegate = serializer.delegate as? (any TaskStoreSerializerDelegate) else { fatalError("delegate must be a TaskStoreSerializerDelegate") }
        let entries = Array(self.tasks)
        let tasks = entries.map(\.value)
        let baseTable = EnvironmentBaseTable(environments: entries.lazy.map { ($0.key, $0.value.environment) })
        // A task that uses a base without changing any value has the base's bindings, so its handles are the base's.
        var bases = [[(StringArena.Handle, StringArena.Handle)]?](repeating: nil, count: baseTable.declaredBases.count)
        for (identifier, task) in entries {
            guard let reference = baseTable.baseReference(for: identifier), reference.positions.isEmpty, bases[reference.index] == nil else { continue }
            bases[reference.index] = handles(of: task).environmentBindings
        }
        let baseHandles = bases.map { bindings in
            guard let bindings else { fatalError("environment base is not used unchanged by any task") }
            return bindings
        }
        serializer.beginAggregate(5)
        serializer.serialize(stringArena)
        serializer.serialize(byteStringArena)
        serializer.serialize(baseHandles.map { $0.map(\.0) })
        serializer.serialize(baseHandles.map { $0.map(\.1) })
        delegate.taskEnvironmentBaseTable = baseTable
        delegate.taskStoreArenas = (stringArena, byteStringArena)
        defer {
            delegate.taskEnvironmentBaseTable = nil
            delegate.taskStoreArenas = nil
        }
        serializer.serialize(tasks)
        serializer.endAggregate()
    }

    package convenience init(from deserializer: any SWBUtil.Deserializer) throws {
        guard let delegate = deserializer.delegate as? (any TaskStoreDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a TaskStoreDeserializerDelegate") }
        try deserializer.beginAggregate(5)
        let strings: FrozenStringArena = try deserializer.deserialize()
        let byteStrings: FrozenByteStringArena = try deserializer.deserialize()
        let baseKeys: [[StringArena.Handle]] = try deserializer.deserialize()
        let baseValues: [[StringArena.Handle]] = try deserializer.deserialize()
        guard baseKeys.count == baseValues.count, zip(baseKeys, baseValues).allSatisfy({ $0.count == $1.count }),
              (baseKeys + baseValues).allSatisfy({ $0.allSatisfy { strings.contains($0) } }) else {
            throw DeserializerError.deserializationFailed("Deserialized environment bases are malformed")
        }
        delegate.taskStoreArenas = (strings, byteStrings)
        delegate.taskEnvironmentBaseHandles = zip(baseKeys, baseValues).map { Array(zip($0, $1)) }
        defer {
            delegate.taskStoreArenas = nil
            delegate.taskEnvironmentBaseHandles = []
        }
        let taskArray: [Task] = try deserializer.deserialize()
        var tasks = [TaskIdentifier: Task](minimumCapacity: taskArray.count)
        for task in taskArray {
            guard tasks.updateValue(task, forKey: task.identifier) == nil else {
                throw DeserializerError.deserializationFailed("Deserialized task store has more than one task '\(task.identifier.rawValue)'")
            }
        }
        self.init(tasks: tasks, stringArena: strings, byteStringArena: byteStrings)
    }

    /// Every task in the store is interned in its arenas.
    private func handles(of task: Task) -> Task.Storage.InternedStorage.Handles {
        guard let handles = task.internedHandles(in: stringArena, byteStringArena) else {
            fatalError("task is not interned in its task store's arenas")
        }
        return handles
    }
}
