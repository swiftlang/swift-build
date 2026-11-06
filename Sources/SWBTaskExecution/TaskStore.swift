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

extension FrozenTaskStore: Serializable {
    package func serialize<T>(to serializer: T) where T : Serializer {
        // The store is written as [base keys, base values, tasks], so the environment bases are read before the tasks that refer to them.
        let tasks = Array(self.tasks.values)
        let delegate = serializer.delegate as? (any TaskEnvironmentSerializerDelegate)
        let baseTable = delegate == nil ? EnvironmentBaseTable() : EnvironmentBaseTable(environments: tasks.lazy.map { ($0.identifier, $0.environment) })
        let bases = baseTable.declaredBases
        serializer.beginAggregate(3)
        serializer.serialize(bases.map { $0.bindings.map(\.0) })
        serializer.serialize(bases.map { $0.bindings.map(\.1) })
        delegate?.taskEnvironmentBaseTable = baseTable
        defer { delegate?.taskEnvironmentBaseTable = nil }
        serializer.serialize(tasks)
        serializer.endAggregate()
    }

    package convenience init(from deserializer: any SWBUtil.Deserializer) throws {
        try deserializer.beginAggregate(3)
        let baseKeys: [[String]] = try deserializer.deserialize()
        let baseValues: [[String]] = try deserializer.deserialize()
        guard baseKeys.count == baseValues.count, zip(baseKeys, baseValues).allSatisfy({ $0.count == $1.count }) else {
            throw DeserializerError.deserializationFailed("Deserialized environment bases contain unbalanced keys and values")
        }
        let delegate = deserializer.delegate as? (any TaskEnvironmentDeserializerDelegate)
        if !baseKeys.isEmpty {
            guard let delegate else { throw DeserializerError.invalidDelegate("delegate must be a TaskEnvironmentDeserializerDelegate") }
            delegate.taskEnvironmentBases = zip(baseKeys, baseValues).map { TaskEnvironmentBase(keys: $0, values: $1) }
        }
        defer { delegate?.taskEnvironmentBases = [] }
        let taskArray: [Task] = try deserializer.deserialize()
        let byteStringArena = ByteStringArena()
        let stringArena = StringArena()
        let baseHandles = TaskEnvironmentBaseHandleCache()
        let tasks = Dictionary(uniqueKeysWithValues: taskArray.map { ($0.identifier, ($0, $0.internedStorage(byteStringArena: byteStringArena, stringArena: stringArena, baseHandles: baseHandles))) })
        let frozenByteStringArena = byteStringArena.freeze()
        let frozenStringArena = stringArena.freeze()
        let internedTasks = tasks.mapValues { taskAndStorage in
            Task(task: taskAndStorage.0, internedStorageHandles: taskAndStorage.1, frozenByteStringArena: frozenByteStringArena, frozenStringArena: frozenStringArena)
        }
        self.init(tasks: internedTasks, stringArena: frozenStringArena, byteStringArena: frozenByteStringArena)
    }
}
