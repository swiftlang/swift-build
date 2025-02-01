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

extension AsyncIteratorProtocol where Element == UInt8 {
    public mutating func nextInt<T: FixedWidthInteger>() async throws -> T? {
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            try await nextInt(isolation: nil)
        } else {
            try await next(count: T.bitWidth / 8).map(T.init(bytes:))
        }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func nextInt<T: FixedWidthInteger>(isolation actor: isolated (any Actor)?) async throws -> T? {
        try await next(count: T.bitWidth / 8, isolation: actor).map(T.init(bytes:))
    }
}

extension AsyncIteratorProtocol {
    public mutating func next(count: Int) async throws -> [Element]? {
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            return try await next(count: count, isolation: nil)
        } else {
            var bytes = [Element]()
            bytes.reserveCapacity(count)
            while bytes.count < count, let byte = try await self.next() {
                bytes.append(byte)
            }
            switch bytes.count {
            case count:
                return bytes
            case 0:
                return nil
            default:
                throw EOFError()
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(count: Int, isolation actor: isolated (any Actor)?) async throws -> [Element]? {
        var bytes = [Element]()
        bytes.reserveCapacity(count)
        while bytes.count < count, let byte = try await self.next(isolation: actor) {
            bytes.append(byte)
        }
        switch bytes.count {
        case count:
            return bytes
        case 0:
            return nil
        default:
            throw EOFError()
        }
    }
}

extension FixedWidthInteger {
    public init(bytes: [UInt8]) {
        self = bytes.withUnsafeBytes { $0.load(as: Self.self) }
    }

    public var bytes: [UInt8] {
        withUnsafeBytes(of: self, Array.init)
    }
}

fileprivate struct EOFError: Error {
}
