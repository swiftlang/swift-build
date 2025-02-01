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

public import Foundation

#if canImport(System)
import System
#else
import SystemPackage
#endif

public final class LineReader {
    private let delimiter: Data
    private let bufferSize: Int

    private var fileHandle: FileDescriptor
    private var buffer: Data
    private var eof: Bool = false

    public init(forReadingFrom url: URL, delimiter: String = "\n", bufferSize: Int = 1024) throws {
        self.delimiter = Data(delimiter.utf8)
        self.bufferSize = bufferSize
        fileHandle = try FileDescriptor.open(FilePath(url.filePath.str), .readOnly)
        buffer = Data(capacity: bufferSize)
    }

    deinit {
        try? fileHandle.close()
    }

    public func rewind() throws {
        try fileHandle.seek(offset: 0, from: .start)
        buffer.removeAll(keepingCapacity: true)
        eof = false
    }

    public func readLine() throws -> String? {
        guard !eof else {
            return nil
        }

        let tmpBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { tmpBuffer.deallocate() }

        repeat {
            if let range = buffer.range(of: delimiter) {
                let line = String(decoding: buffer.subdata(in: buffer.startIndex..<range.lowerBound), as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            } else {
                let count = try fileHandle.read(into: tmpBuffer)
                if count == 0 {
                    eof = true
                    return !buffer.isEmpty ? String(decoding: buffer, as: UTF8.self) : nil
                }
                buffer.append(Data(tmpBuffer[0..<count]))
            }
        } while true
    }
}

@available(*, unavailable)
extension LineReader: Sendable { }
