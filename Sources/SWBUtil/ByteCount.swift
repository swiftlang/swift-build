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

public struct ByteCount: Hashable, Sendable {
    public var count: Int64

    public init?(_ count: Int64?) {
        guard let count else { return nil }
        self.count = count
    }

    public init(_ count: Int64) {
        self.count = count
    }
}

extension ByteCount: Codable {
    public init(from decoder: any Swift.Decoder) throws {
        self.count = try .init(from: decoder)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try self.count.encode(to: encoder)
    }
}

extension ByteCount: Serializable {
    public init(from deserializer: any Deserializer) throws {
        self.count = try .init(from: deserializer)
    }

    public func serialize<T>(to serializer: T) where T: Serializer {
        self.count.serialize(to: serializer)
    }
}

extension ByteCount: Comparable {
    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.count < rhs.count
    }
}

extension ByteCount: AdditiveArithmetic {
    public static var zero: ByteCount {
        Self(0)
    }

    public static func + (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        Self(lhs.count + rhs.count)
    }

    public static func - (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        Self(lhs.count - rhs.count)
    }
}

extension ByteCount: CustomStringConvertible {
    public var description: String {
        "\(count) bytes"
    }
}

extension ByteCount {
    private static let kb = Int64(1024)
    private static let mb = kb * 1024
    private static let gb = mb * 1024
    private static let tb = gb * 1024

    public static func kilobytes(_ count: Int64) -> Self {
        Self(kb * count)
    }

    public static func megabytes(_ count: Int64) -> Self {
        Self(mb * count)
    }

    public static func gigabytes(_ count: Int64) -> Self {
        Self(gb * count)
    }

    public static func terabytes(_ count: Int64) -> Self {
        Self(tb * count)
    }
}
