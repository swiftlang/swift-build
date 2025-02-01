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

// copied from `test/Concurrency/Runtime/async_sequence.swift` in the Swift repository
extension AsyncSequence {
    @inlinable
    public func collect() async rethrows -> [Element] {
        var items = [Element]()
        var it = makeAsyncIterator()
        while let e = try await it.next() {
            items.append(e)
        }
        return items
    }
}

extension TaskGroup where Element == Void {
    /// Concurrency-friendly replacement for `DispatchQueue.concurrentPerform(iterations:execute:)`.
    public static func concurrentPerform(iterations: Int, maximumParallelism: Int, execute work: @Sendable @escaping (Int) async -> Element) async {
        var started = 0
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    await work(i)
                }

                started += 1

                if started >= maximumParallelism {
                    await group.next()
                }
            }
            await group.waitForAll()
        }
    }
}

extension ThrowingTaskGroup where Element == Void, Failure == any Error {
    /// Concurrency-friendly replacement for `DispatchQueue.concurrentPerform(iterations:execute:)`.
    public static func concurrentPerform(iterations: Int, maximumParallelism: Int, execute work: @Sendable @escaping (Int) async throws -> Element) async throws {
        var started = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    try await work(i)
                }

                started += 1

                if started >= maximumParallelism {
                    try await group.next()
                }
            }
            try await group.waitForAll()
        }
    }
}

extension Sequence where Element: Sendable {
    public func parallelForEach<Void>(
        group: inout TaskGroup<Void>,
        maximumParallelism: Int,
        _ body: @Sendable @escaping (Element) async -> Void
    ) async {
        var started = 0
        for element in self {
            group.addTask {
                await body(element)
            }
            started += 1

            if started >= maximumParallelism {
                _ = await group.next()
            }
        }
    }

    public func parallelForEach<Void, U>(
        group: inout ThrowingTaskGroup<Void, U>,
        maximumParallelism: Int,
        _ body: @Sendable @escaping (Element) async throws -> Void
    ) async throws {
        var started = 0
        for element in self {
            group.addTask {
                try await body(element)
            }
            started += 1

            if started >= maximumParallelism {
                _ = try await group.next()
            }
        }
    }
}

@_alwaysEmitIntoClient
public func withExtendedLifetime<T: ~Copyable, E: Error, Result: ~Copyable>(
    _ x: borrowing T,
    _ body: (borrowing T) async throws(E) -> Result
) async throws(E) -> Result {
    defer { withExtendedLifetime(x) { } }
    return try await body(x)
}
