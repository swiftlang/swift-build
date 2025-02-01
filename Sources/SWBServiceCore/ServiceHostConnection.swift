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

import SWBLibc
import SWBUtil
import Foundation

#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Convert a count to a UInt8 buffer.
private func int32ToArray(_ value: UnsafePointer<Int32>) -> [UInt8] {
    return value.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<Int32>.size) { Array(UnsafeBufferPointer(start: $0, count: MemoryLayout<Int32>.size)) }
}
private func int64ToArray(_ value: UnsafePointer<UInt64>) -> [UInt8] {
    return value.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<UInt64>.size) { Array(UnsafeBufferPointer(start: $0, count: MemoryLayout<Int64>.size)) }
}

public enum ServiceHostConnectionMode: Sendable {
    case inProcess
    case outOfProcess
}

/// This class manages the connection to the build service host.
///
/// This class is designed to be thread safe: clients can send messages from any thread and they will be sent in FIFO order. Received messages are, however, only processed one at a time in FIFO order.
final class ServiceHostConnection: @unchecked Sendable {
    /// The shutdown handler.
    var shutdownHandler: @Sendable (_ error: (any Error)?) -> Void = { (_) in }

    /// The client handler.
    var handler: (UInt64, [UInt8]) async -> Void = { (_, _) in }

    /// Whether the queue is suspended.
    private let isSuspended = LockedValue(true)

    /// The queue used to read incoming messages.
    private let receiveQueue: SWBQueue

    /// The queue used to send outgoing messages.
    private let sendQueue: SWBQueue

    /// The file descriptor to read on.
    private let inputFD: FileDescriptor

    /// The file descriptor to write on.
    private let outputFD: FileDescriptor

    /// Create a new connection to the host process.
    ///
    /// The connection input and output pipes are assumed to be provided on stdin and stdout, with a normal output stream on stderr. As part of initialization, the connection will clone the IO pipes to stable file descriptors and replace stdout with the stderr stream, so that the program can use regular print statements and have them go to a visible output stream.
    ///
    /// - Parameters:
    ///   - inputFD: The input file descriptor for incoming messages.
    ///   - outputFD: The output file descriptor for outgoing messages.
    init(inputFD: FileDescriptor, outputFD: FileDescriptor) {
        self.inputFD = inputFD
        self.outputFD = outputFD
        // The queues for the service host connection are given .userInitiated QOS (not .utility, which most queues in Swift Build have) because we don't know whether we're servicing a user interaction request.  Most requests should be shunted to a background thread unless there's a reason to send a quick response at high priority.
        self.receiveQueue = SWBQueue(label: "SWBBuildService.ServiceHostConnection.receiveQueue", qos: .userInitiated, autoreleaseFrequency: .workItem)
        self.sendQueue = SWBQueue(label: "SWBBuildService.ServiceHostConnection.sendQueue", qos: .userInitiated, autoreleaseFrequency: .workItem)
    }

    /// Extract and handle all messages in the given buffer, returning the number of remaining bytes.
    ///
    /// - start: A pointer to the start of the buffer.
    /// - count: The number of bytes in the buffer.
    /// - returns: The number of unhandled bytes at the end of the buffer.
    private func extractAndHandleMessages(_ start: UnsafePointer<UInt8>, _ count: Int) async -> Int {
        var start = start
        var count = count
        while count > MemoryLayout<UInt64>.size + MemoryLayout<Int32>.size {
            // The message header consist of a 64-bit channel number followed by a 32-bit payload size.
            let headerSize = MemoryLayout<UInt64>.size + MemoryLayout<Int32>.size
            var channelValue: UInt64 = 0
            withUnsafeMutableBytes(of: &channelValue) { valuePtr in
                valuePtr.copyBytes(from: UnsafeRawBufferPointer(start: start, count: MemoryLayout<UInt64>.size))
            }
            let channelID = UInt64(littleEndian: channelValue)

            var sizeValue: UInt32 = 0
            withUnsafeMutableBytes(of: &sizeValue) { valuePtr in
                valuePtr.copyBytes(from: UnsafeRawBufferPointer(start: start.advanced(by: MemoryLayout<UInt64>.size), count: MemoryLayout<UInt32>.size))
            }
            let payloadSize = Int(UInt32(littleEndian: sizeValue))
            let totalSize = headerSize + payloadSize

            #if DEBUG
            // A well behaved client would not send a negative payloadSize, but this can happen when we hit <rdar://problem/62081788>.
            // In that case, consider all remaining bytes to be bogus and drop them.
            if payloadSize < 0 {
                count = 0
                break
            }
            #endif

            // If we do not have a complete message, we are done.
            if count < totalSize {
                break
            }

            // Otherwise, handle the packet and continue.
            await self.handler(channelID, Array<UInt8>(UnsafeBufferPointer(start: start.advanced(by: headerSize), count: payloadSize)))

            // Advance to the start of the next packet.
            start = start.advanced(by: totalSize)
            count -= totalSize
        }
        return count
    }

    func suspend() {
        isSuspended.withLock { $0 = true }
    }

    /// Resume the connection.
    ///
    /// NOTE: The service will automatically stop the entire process when the connection is closed.
    func resume() {
        // If the connection not suspended, do nothing.
        if !isSuspended.withLock({ $0 }) {
            return
        }

        // Otherwise, launch the receive pump.
        isSuspended.withLock { $0 = false }
        receiveQueue.async {
            // Read data forever.
            var data: [UInt8] = []
            let tmpBufferSize = 4096
            let tmp = UnsafeMutableBufferPointer(start: UnsafeMutablePointer<UInt8>.allocate(capacity: tmpBufferSize), count: tmpBufferSize)

            var error: (any Error)?
            while !self.isSuspended.withLock({ $0 }) {
                #if DEBUG
                // Work around <rdar://problem/62081788> read syscall can sometimes return a value greater than the count parameter
                // We set the whole buffer to 0xFF so that parts that are not written will be interpreted as a payload with a negative length.
                // This is only a mitigation that may not catch all cases.
                tmp.update(repeating: 0xFF)
                #endif

                // Read data.
                let result = read(self.inputFD.rawValue, tmp.baseAddress, numericCast(tmpBufferSize))
                if result < 0 {
                    if errno == EINTR { continue }
                    error = ServiceHostIOError(message: "read from client failed", cause: SWBUtil.POSIXError(errno, context: "read"))
                    break
                }
                if result == 0 {
                    if !data.isEmpty {
                        log("warning: connection closed with data remaining")
                    }
                    break
                }
                #if DEBUG
                if result > tmpBufferSize {
                    log("warning: read returned more bytes than requested: \(result) > \(tmpBufferSize)")
                }
                #endif

                // Extract all the messages, combining into a contiguous buffer first if necessary.
                if !data.isEmpty {
                    data.append(contentsOf: UnsafeBufferPointer(start: tmp.baseAddress, count: Int(result)))
                    let dataCopy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
                    defer {
                        dataCopy.deallocate()
                    }
                    data.copyBytes(to: dataCopy)
                    let remaining = await self.extractAndHandleMessages(dataCopy.baseAddress!, dataCopy.count)

                    // Update data to contain only the remaining data.
                    assert(remaining <= data.count)
                    if remaining != data.count {
                        data = Array<UInt8>(data[data.count - remaining..<data.count])
                    }
                } else {
                    let remaining = await self.extractAndHandleMessages(tmp.baseAddress!, Int(result))

                    // Set data to the remaining data, if present.
                    if remaining != 0 {
                        data = Array<UInt8>(UnsafeBufferPointer(start: tmp.baseAddress!.advanced(by: Int(result) - remaining), count: remaining))
                    }
                }
            }

            tmp.deallocate()

            // If the receive pump stops, tell the service to shut down.
            //
            // FIXME: We may at some point need to coordinate with outstanding work.
            self.shutdownHandler(error)
        }
    }

    /// Send a message.
    func send(_ channel: UInt64, _ message: [UInt8]) {
        sendQueue.async {
            var channel = channel
            // FIXME: We should switch to using Dispatch.
            guard var length = Int32(exactly: message.count) else {
                return self.shutdownHandler(ServiceHostIOError(message: "Message too large", cause: nil))
            }
            let header = int64ToArray(&channel) + int32ToArray(&length)

            do {
                try self.outputFD.writeAll(header + message)
            } catch {
                self.shutdownHandler(ServiceHostIOError(message: "write of \(length) bytes on channel \(channel) failed - the client may have exited", cause: error))
            }
        }
    }

    /// Send a message.
    func send(_ channel: UInt64, _ message: ByteString) {
        send(channel, message.bytes)
    }
}

private struct ServiceHostIOError: Error, CustomStringConvertible {
    public let message: String
    public let cause: (any Error)?

    public init(message: String, cause: (any Error)?) {
        self.message = message
        self.cause = cause
    }

    public var description: String {
        return "\(message) (\(cause?.localizedDescription ?? "unknown cause"))"
    }
}
