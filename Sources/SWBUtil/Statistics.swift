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

import Synchronization

/// A scope to contain a group of statistics.
public final class StatisticsGroup: Sendable {
    /// The name for this group.
    public let name: String

    private let _statistics = LockedValue<[any _StatisticBackend]>([])

    /// The list of statistics in the group.
    public var statistics: [any _StatisticBackend] { return _statistics.withLock { $0 } }

    public init(_ name: String) {
        self.name = name
    }

    public func register(_ statistic: any _StatisticBackend) {
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
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2, *)
public final class _Statistic: @unchecked Sendable, _StatisticBackend {
    /// The name of the statistics.
    public let name: String

    /// The description of the statistics.
    public let description: String

    /// The value of the statistic.
    private let _value = Atomic<Int>(0)

    public init(_ name: String, _ description: String, _ group: StatisticsGroup = allStatistics) {
        self.name = name
        self.description = description

        group.register(self)
    }

    /// Get the current value of the statistic.
    public var value: Int {
        return _value.load(ordering: .relaxed)
    }

    /// Increment the statistic.
    public func increment(_ n: Int = 1) {
        _value.wrappingAdd(n, ordering: .relaxed)
    }

    /// Zero all of the statistics.
    ///
    /// This is useful when using statistics to probe program behavior from within tests, and the test can guarantee no concurrent access.
    public func zero() {
        _value.store(0, ordering: .relaxed)
    }
}

/// The singleton statistics group.
public let allStatistics = StatisticsGroup("swift-build")

// MARK: Utilities

public func +=(statistic: Statistic, rhs: Int = 1) {
    statistic.increment(rhs)
}

// MARK: Back-deployment

public final class Statistic: @unchecked Sendable, _StatisticBackend {
    public let name: String
    private let _statistic: (any _StatisticBackend)?

    public init(_ name: String, _ description: String, _ group: StatisticsGroup = allStatistics) {
        self.name = name
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            _statistic = _Statistic(name, description, group)
        } else {
            _statistic = nil
        }
    }

    public var value: Int {
        _statistic?.value ?? 0
    }

    public func increment(_ n: Int) {
        _statistic?.increment(n)
    }

    public func zero() {
        _statistic?.zero()
    }
}

public protocol _StatisticBackend: Sendable {
    var name: String { get }
    var value: Int { get }
    func increment(_ n: Int)
    func zero()
}

extension _StatisticBackend {
    public func increment() {
        self.increment(1)
    }
}
