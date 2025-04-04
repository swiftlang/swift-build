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

/// A key used to access values in an ``Environment``.
///
/// This type respects the compiled platform's case sensitivity requirements.
public struct EnvironmentKey {
    public var rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension EnvironmentKey {
    package static let path: Self = "PATH"
}

extension EnvironmentKey {
    package static let developerDir: Self = "DEVELOPER_DIR"
}

extension EnvironmentKey: CodingKeyRepresentable {}

extension EnvironmentKey: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        // Even on windows use a stable sort order.
        lhs.rawValue < rhs.rawValue
    }
}

extension EnvironmentKey: CustomStringConvertible {
    public var description: String { self.rawValue }
}

extension EnvironmentKey: Encodable {
    public func encode(to encoder: any Swift.Encoder) throws {
        try self.rawValue.encode(to: encoder)
    }
}

extension EnvironmentKey: Equatable {
    public static func == (_ lhs: Self, _ rhs: Self) -> Bool {
        #if os(Windows)
        lhs.rawValue.lowercased() == rhs.rawValue.lowercased()
        #else
        lhs.rawValue == rhs.rawValue
        #endif
    }
}

extension EnvironmentKey: ExpressibleByStringLiteral {
    public init(stringLiteral rawValue: String) {
        self.init(rawValue)
    }
}

extension EnvironmentKey: Decodable {
    public init(from decoder: any Swift.Decoder) throws {
        self.rawValue = try String(from: decoder)
    }
}

extension EnvironmentKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        #if os(Windows)
        self.rawValue.lowercased().hash(into: &hasher)
        #else
        self.rawValue.hash(into: &hasher)
        #endif
    }
}

extension EnvironmentKey: RawRepresentable {
    public init?(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension EnvironmentKey: Sendable {}
