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

package final class TaskStore {
    package enum Error: Swift.Error {
        case duplicateTaskIdentifier
    }

    private var tasks: [TaskIdentifier: Task]
    private let stringArena = StringArena()
    private let byteStringArena = ByteStringArena()

    init() {
        tasks = [:]
    }

    private init(tasks: [TaskIdentifier: Task]) {
        self.tasks = tasks
        for task in tasks.values {
            task.intern(byteStringArena: byteStringArena, stringArena: stringArena)
        }
    }

    package func insertTask(_ task: Task) throws -> TaskIdentifier {
        let id = task.identifier
        guard !tasks.keys.contains(id) else {
            throw Error.duplicateTaskIdentifier
        }
        tasks[id] = task
        task.intern(byteStringArena: byteStringArena, stringArena: stringArena)
        return id
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

    package var taskCount: Int {
        tasks.count
    }

    /// It is beneficial for the performance of the index queries to have a mapping of tasks in each target.
    /// But since this is not broadly useful we only populate this lazily, on demand. This info is not serialized to the build description.
    private var tasksByTargetCache: LockedValue<[ConfiguredTarget?: [Task]]> = .init([:])

    /// The tasks associated with a particular target.
    package func tasksForTarget(_ target: ConfiguredTarget?) -> [Task] {
        return tasksByTargetCache.withLock { tasksByTarget in
            tasksByTarget.getOrInsert(target) { tasks.values.filter { $0.forTarget == target } }
        }
    }
}

// TaskStore is not Sendable
@available(*, unavailable) extension TaskStore: Sendable {}

extension TaskStore: Serializable {
    package func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serialize(Array(tasks.values))
    }

    package convenience init(from deserializer: any SWBUtil.Deserializer) throws {
        let taskArray: [Task] = try deserializer.deserialize()
        self.init(tasks: Dictionary(uniqueKeysWithValues: taskArray.map { ($0.identifier, $0) }))
    }
}
