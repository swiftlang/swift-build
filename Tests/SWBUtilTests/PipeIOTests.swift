//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SWBUtil
import SWBTestSupport
import Testing

#if canImport(System)
import System
#else
import SystemPackage
#endif

@Suite fileprivate struct PipeIOTests {
    private func readToEnd(_ fileDescriptor: FileDescriptor) async throws -> [UInt8] {
        var result: [UInt8] = []
        while let chunk = try await PipeIO.read(from: fileDescriptor, upTo: 4096) {
            result += chunk
        }
        return result
    }

    @Test
    func roundTrip() async throws {
        let (readEnd, writeEnd) = try PipeIO.makePipe()
        let bytes = Array("hello world".utf8)
        #expect(try await PipeIO.write(bytes, to: writeEnd) == bytes.count)
        #expect(try await PipeIO.read(from: readEnd, upTo: 4096) == bytes)
        try PipeIO.close(writeEnd)
        #expect(try await PipeIO.read(from: readEnd, upTo: 4096) == nil)
        try PipeIO.close(readEnd)
    }

    @Test
    func readWaitsForData() async throws {
        let (readEnd, writeEnd) = try PipeIO.makePipe()
        let reader = Task {
            try await PipeIO.read(from: readEnd, upTo: 4096)
        }
        // Give the read a chance to start waiting.
        try await Task.sleep(for: .milliseconds(100))
        try await PipeIO.write([1, 2, 3], to: writeEnd)
        #expect(try await reader.value == [1, 2, 3])
        try PipeIO.close(writeEnd)
        try PipeIO.close(readEnd)
    }

    @Test
    func writeLargerThanPipeBuffer() async throws {
        let (readEnd, writeEnd) = try PipeIO.makePipe()
        let bytes = (0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 % 251) }
        let writer = Task {
            let written = try await PipeIO.write(bytes, to: writeEnd)
            try PipeIO.close(writeEnd)
            return written
        }
        #expect(try await readToEnd(readEnd) == bytes)
        #expect(try await writer.value == bytes.count)
        try PipeIO.close(readEnd)
    }

    @Test
    func orderedWritesAcrossManyPipes() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let (readEnd, writeEnd) = try PipeIO.makePipe()
                    let messages = (0..<100).map { Array("\(index):\($0);".utf8) }
                    async let received = readToEnd(readEnd)
                    for message in messages {
                        try await PipeIO.write(message, to: writeEnd)
                    }
                    try PipeIO.close(writeEnd)
                    #expect(try await received == messages.flatMap { $0 })
                    try PipeIO.close(readEnd)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test
    func cancellingPendingRead() async throws {
        let (readEnd, writeEnd) = try PipeIO.makePipe()
        let reader = Task {
            try await PipeIO.read(from: readEnd, upTo: 4096)
        }
        // Give the read a chance to start waiting.
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        #expect(try await reader.value == nil)
        try PipeIO.close(writeEnd)
        try PipeIO.close(readEnd)
    }
}
