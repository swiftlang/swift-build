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

public struct AsyncFlatteningSequence<Base: AsyncSequence>: AsyncSequence where Base.Element: RandomAccessCollection {
    public typealias Element = Base.Element.Element

    var base: Base

    public struct AsyncIterator: AsyncIteratorProtocol {
        var _base: Base.AsyncIterator
        var buffer: (bytes: Base.Element, index: Base.Element.Index)?

        internal init(underlyingIterator: Base.AsyncIterator) {
            _base = underlyingIterator
        }

        public mutating func next() async throws -> Element? {
            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
                return try await next(isolation: #isolation)
            } else {
                if isAtEnd {
                    buffer = nil
                    while isEmpty {
                        guard let next = try await _base.next() else {
                            return nil
                        }
                        buffer = (next, next.startIndex)
                    }
                }
                return nextElement()
            }
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        public mutating func next(isolation actor: isolated (any Actor)?) async throws(any Error) -> Element? {
            if isAtEnd {
                buffer = nil
                while isEmpty {
                    guard let next = try await _base.next(isolation: actor) else {
                        return nil
                    }
                    buffer = (next, next.startIndex)
                }
            }
            return nextElement()
        }

        private var isAtEnd: Bool {
            guard let buffer else { return true }
            return buffer.bytes.endIndex == buffer.index
        }

        private var isEmpty: Bool {
            guard let buffer else { return true }
            return buffer.bytes.isEmpty
        }

        private mutating func nextElement() -> Element {
            guard var buffer else { preconditionFailure() }
            defer {
                buffer.index = buffer.bytes.index(after: buffer.index)
                self.buffer = buffer
            }
            return buffer.bytes[buffer.index]
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(underlyingIterator: base.makeAsyncIterator())
    }

    internal init(underlyingSequence: Base) {
        base = underlyingSequence
    }
}

extension AsyncSequence where Self.Element: RandomAccessCollection, Element.Element == UInt8 {
    public var flattened: AsyncFlatteningSequence<Self> {
        AsyncFlatteningSequence(underlyingSequence: self)
    }
}

extension AsyncFlatteningSequence: Sendable where Base: Sendable { }

@available(*, unavailable)
extension AsyncFlatteningSequence.AsyncIterator: Sendable { }
