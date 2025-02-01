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

/// A scope to contain a group of statistics.
public final class StatisticsGroup: Sendable {
    /// The name for this group.
    public let name: String

    private let _statistics = LockedValue<[Statistic]>([])

    /// The list of statistics in the group.
    public var statistics: [Statistic] { return _statistics.withLock { $0 } }

    public init(_ name: String) {
        self.name = name
    }

    public func register(_ statistic: Statistic) {
        _statistics.withLock { $0.append(statistic) }
    }

    /// Zero all of the statistics.
    ///
    /// This is useful when using statistics to probe program behavior from within tests, and the test can guarantee no concurrent access.
    public func zero() {
        _statistics.withLock { $0.forEach{ $0.zero() } }
    }
}

/// An individual statistic.
///
/// Currently statistics are always integers and are not thread safe (unless building in TSan mode); clients should implement their own locking if an accurate count is required.
// FIXME: This should unconditionally be implemented using atomics, not conditionally be using a queue based on TSan...
public final class Statistic: @unchecked Sendable {
    /// The name of the statistics.
    public let name: String

    /// The description of the statistics.
    public let description: String

    #if ENABLE_THREAD_SANITIZER
    /// Queue to serialize access to the statistic value.
    let _queue = SWBQueue(label: "com.apple.dt.SWBUtil.Statistics")
    #endif

    /// The value of the statistic.
    var _value: Int = 0

    public init(_ name: String, _ description: String, _ group: StatisticsGroup = allStatistics) {
        self.name = name
        self.description = description

        group.register(self)
    }

    /// Get the current value of the statistic.
    public var value: Int {
        return sync { _value }
    }

    /// Increment the statistic.
    public func increment(_ n: Int = 1) {
        sync { _value += n }
    }

    /// Zero all of the statistics.
    ///
    /// This is useful when using statistics to probe program behavior from within tests, and the test can guarantee no concurrent access.
    public func zero() {
        sync { _value = 0 }
    }

    /// Helper method to execute a block on our serial queue (if it's enabled).
    public func sync<T>(execute work: () throws -> T) rethrows -> T {
        #if ENABLE_THREAD_SANITIZER
        return try _queue.blocking_sync { try work() }
        #else
        return try work()
        #endif
    }
}

/// The singleton statistics group.
public let allStatistics = StatisticsGroup("swift-build")

// MARK: Utilities

public func +=(statistic: Statistic, rhs: Int = 1) {
    statistic.increment(rhs)
}
