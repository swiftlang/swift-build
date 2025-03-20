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

import Foundation

public struct Environment {
    var storage: [EnvironmentKey: String]
}

// MARK: - Accessors

extension Environment {
    package init() {
        self.storage = .init()
    }

    package subscript(_ key: EnvironmentKey) -> String? {
        _read { yield self.storage[key] }
        _modify { yield &self.storage[key] }
    }
}

// MARK: - Conversions between Dictionary<String, String>

extension Environment {
    public init(_ dictionary: [String: String]) {
        self.storage = .init()
        let sorted = dictionary.sorted { $0.key < $1.key }
        for (key, value) in sorted {
            self.storage[.init(key)] = value
        }
    }
}

extension [String: String] {
    public init(_ environment: Environment) {
        self.init()
        let sorted = environment.sorted { $0.key < $1.key }
        for (key, value) in sorted {
            self[key.rawValue] = value
        }
    }
}

// MARK: - Path Modification

extension Environment {
    package mutating func prependPath(key: EnvironmentKey, value: String) {
        guard !value.isEmpty else { return }
        if let existing = self[key] {
            self[key] = "\(value)\(Path.pathEnvironmentSeparator)\(existing)"
        } else {
            self[key] = value
        }
    }

    package mutating func appendPath(key: EnvironmentKey, value: String) {
        guard !value.isEmpty else { return }
        if let existing = self[key] {
            self[key] = "\(existing)\(Path.pathEnvironmentSeparator)\(value)"
        } else {
            self[key] = value
        }
    }
}

// MARK: - Global Environment

extension Environment {
    /// Vends a copy of the current process's environment variables.
    public static var current: Self {
        Self(ProcessInfo.processInfo.cleanEnvironment)
    }
}

// MARK: - Protocol Conformances

extension Environment: Collection {
    public struct Index: Comparable, Sendable {
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.underlying < rhs.underlying
        }

        var underlying: Dictionary<EnvironmentKey, String>.Index
    }

    public typealias Element = (key: EnvironmentKey, value: String)

    public var startIndex: Index {
        Index(underlying: self.storage.startIndex)
    }

    public var endIndex: Index {
        Index(underlying: self.storage.endIndex)
    }

    public subscript(index: Index) -> Element {
        self.storage[index.underlying]
    }

    public func index(after index: Self.Index) -> Self.Index {
        Index(underlying: self.storage.index(after: index.underlying))
    }
}

extension Environment: CustomStringConvertible {
    public var description: String {
        let body = self
            .sorted { $0.key < $1.key }
            .map { "\"\($0.rawValue)=\($1)\"" }
            .joined(separator: ", ")
        return "[\(body)]"
    }
}

extension Environment: Encodable {
    public func encode(to encoder: any Swift.Encoder) throws {
        try self.storage.encode(to: encoder)
    }
}

extension Environment: Equatable {}

extension Environment: ExpressibleByDictionaryLiteral {
    public typealias Key = EnvironmentKey
    public typealias Value = String

    public init(dictionaryLiteral elements: (Key, Value)...) {
        self.storage = .init()
        for (key, value) in elements {
            self.storage[key] = value
        }
    }
}

extension Environment: Decodable {
    public init(from decoder: any Swift.Decoder) throws {
        self.storage = try .init(from: decoder)
    }
}

extension Environment: Sendable {}

extension Environment {
    public func filter(_ isIncluded: @escaping (Dictionary<EnvironmentKey, String>.Element) throws -> Bool) rethrows -> Environment {
        try Environment(storage: storage.filter(isIncluded))
    }

    public func filter<KeyCollection: Collection>(keys: KeyCollection) -> Environment where KeyCollection.Element == EnvironmentKey {
        return filter { key, _ in keys.contains(key) }
    }

    public mutating func addContents(of other: Environment) {
        storage.addContents(of: other.storage)
    }

    public func addingContents(of other: Environment) -> Environment {
        var env = self
        env.addContents(of: other)
        return env
    }

    public mutating func addContents(of other: [EnvironmentKey: String]) {
        storage.addContents(of: other)
    }

    public func addingContents(of other: [EnvironmentKey: String]) -> Environment {
        var env = self
        env.addContents(of: other)
        return env
    }

}
