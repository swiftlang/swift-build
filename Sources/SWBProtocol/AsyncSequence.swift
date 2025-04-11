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

import SWBUtil

extension FixedWidthInteger {
    public init(protocolEndian value: Self) {
        self.init(littleEndian: value)
    }

    public var protocolEndian: Self {
        littleEndian
    }
}

/// An async sequence whose elements are a Swift Build IPC message - a tuple of a channel ID and a sequence of bytes constituting the message contents.
public struct AsyncIPCMessageSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = (UInt64, [UInt8])

    var base: Base

    fileprivate struct EOFError: Error {
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var _base: Base.AsyncIterator

        internal init(underlyingIterator: Base.AsyncIterator) {
            _base = underlyingIterator
        }

        public mutating func next() async throws -> Element? {
            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
                return try await next(isolation: nil)
            } else {
                // The message header consist of a 64-bit channel number followed by a 32-bit payload size.
                guard let channelID = try await _base.nextInt().map(UInt64.init(protocolEndian:)) else {
                    // If we reach EOF here it's expected as there are simply no more messages
                    return nil
                }

                guard let payloadSize = try await _base.nextInt().map(Int32.init(protocolEndian:)) else {
                    // We already started reading a message, if we fail here it's unexpectedly EOF
                    throw EOFError()
                }

                // Int32 -> Int can never fail on any architecture
                guard let payloadBytes = try await _base.next(count: Int(payloadSize)) else {
                    // We already started reading a message, if we fail here it's unexpectedly EOF
                    throw EOFError()
                }

                return (channelID, payloadBytes)
            }
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        public mutating func next(isolation actor: isolated (any Actor)?) async throws(any Error) -> Element? {
            // The message header consist of a 64-bit channel number followed by a 32-bit payload size.
            guard let channelID = try await _base.nextInt(isolation: actor).map(UInt64.init(protocolEndian:)) else {
                // If we reach EOF here it's expected as there are simply no more messages
                return nil
            }

            guard let payloadSize = try await _base.nextInt(isolation: actor).map(Int32.init(protocolEndian:)) else {
                // We already started reading a message, if we fail here it's unexpectedly EOF
                throw EOFError()
            }

            // Int32 -> Int can never fail on any architecture
            guard let payloadBytes = try await _base.next(count: Int(payloadSize), isolation: actor) else {
                // We already started reading a message, if we fail here it's unexpectedly EOF
                throw EOFError()
            }

            return (channelID, payloadBytes)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(underlyingIterator: base.makeAsyncIterator())
    }

    internal init(underlyingSequence: Base) {
        base = underlyingSequence
    }
}

extension AsyncSequence where Self.Element == UInt8 {
    public var ipcMessages: AsyncIPCMessageSequence<Self> {
        AsyncIPCMessageSequence(underlyingSequence: self)
    }
}

extension AsyncIPCMessageSequence: Sendable where Base: Sendable { }

@available(*, unavailable)
extension AsyncIPCMessageSequence.AsyncIterator: Sendable { }
