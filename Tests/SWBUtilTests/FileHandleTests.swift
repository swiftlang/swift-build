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
import SWBUtil
import SWBTestSupport
import Testing

#if canImport(System)
import System
#else
import SystemPackage
#endif

@Suite fileprivate struct FileHandleTests {
    @Test
    func asyncReadFileDescriptor() async throws {
        let fs = localFS
        try await withTemporaryDirectory(fs: fs) { testDataPath in
            let plistPath = testDataPath.join("testData")
            try fs.write(plistPath, contents: ByteString([UInt8](repeating: 0, count: 1448)))
            #expect(fs.exists(plistPath))
            let plist = try fs.read(plistPath)
            #expect(plist.count == 1448)

            // Read the whole file
            do {
                let fd = try FileDescriptor.open(FilePath(plistPath.str), .readOnly)
                let fh = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: false)
                try await fd.closeAfter {
                    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
                        var it = fh.bytes(on: .global()).makeAsyncIterator()
                        var bytesOfFile: [UInt8] = []
                        await #expect(throws: Never.self) {
                            while let byte = try await it.next() {
                                bytesOfFile.append(byte)
                            }
                        }
                        #expect(bytesOfFile.count == 1448)
                        #expect(plist.bytes == bytesOfFile)
                    } else {
                        var it = fh._bytes(on: .global()).makeAsyncIterator()
                        var bytesOfFile: [UInt8] = []
                        await #expect(throws: Never.self) {
                            while let byte = try await it.next() {
                                bytesOfFile.append(byte)
                            }
                        }
                        #expect(bytesOfFile.count == 1448)
                        #expect(plist.bytes == bytesOfFile)
                    }
                }
            }

            if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
                // no /dev/zero equivalent on Windows, and reading the root drive fails immediately
                return
            }

            // Read while triggering an I/O error
            do {
                let fd = try Path.root.str.withPlatformString { try FileDescriptor.open($0, .readOnly) }
                let fh = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: false)

                if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
                    var it = fh.bytes(on: .global()).makeAsyncIterator()
                    try fd.close()

                    await #expect(throws: (any Error).self) {
                        while let _ = try await it.next() {
                        }
                    }
                } else {
                    var it = fh._bytes(on: .global()).makeAsyncIterator()
                    try fd.close()

                    await #expect(throws: (any Error).self) {
                        while let _ = try await it.next() {
                        }
                    }
                }
            }

            // Read part of a file, then close the handle
            do {
                let condition = CancellableWaitCondition()

                let reader = Task<Void, any Error>.detached {
                    let fd = try FileDescriptor.open("/dev/zero", .readOnly)
                    try await fd.closeAfter {
                        let fh = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: false)
                        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
                            var it = fh.bytes(on: .global()).makeAsyncIterator()
                            var bytes: [UInt8] = []
                            while let byte = try await it.next() {
                                bytes.append(byte)
                                if bytes.count == 100 {
                                    condition.signal()
                                    throw CancellationError()
                                }
                            }
                        } else {
                            var it = fh._bytes(on: .global()).makeAsyncIterator()
                            var bytes: [UInt8] = []
                            while let byte = try await it.next() {
                                bytes.append(byte)
                                if bytes.count == 100 {
                                    condition.signal()
                                    throw CancellationError()
                                }
                            }
                        }

                        try Task.checkCancellation()
                    }
                }

                try await condition.wait()

                reader.cancel()

                await #expect(throws: CancellationError.self) {
                    try await reader.value
                }
            }
        }
    }
}
