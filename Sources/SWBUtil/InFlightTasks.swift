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

/// Lets identical requests share a task while it is in flight.
public final class InFlightTasks<Key: Equatable & Sendable, Value: Sendable>: Sendable {
    private let tasks = SWBMutex<[(key: Key, task: Task<Value, Never>)]>([])

    public init() { }

    public func task(for key: Key, priority: TaskPriority? = nil, _ body: @escaping @Sendable () async -> Value) -> Task<Value, Never> {
        tasks.withLock { tasks in
            if let task = tasks.first(where: { $0.key == key })?.task {
                return task
            }
            let task = Task(priority: priority) {
                let value = await body()
                self.tasks.withLock { $0.removeAll { $0.key == key } }
                return value
            }
            tasks.append((key, task))
            return task
        }
    }

    public var count: Int {
        tasks.withLock { $0.count }
    }
}
