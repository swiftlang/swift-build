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

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

extension Service {
    public static func main(_ setupFileDescriptors: (_ inputFD: FileDescriptor, _ outputFD: FileDescriptor) async throws -> Void) async throws {
        #if os(macOS)
        do {
            try await Debugger.waitForXcodeAutoAttachIfEnabled()
        } catch {
            throw StubError.error("Failed to attach debugger: \(error)")
        }
        #endif

        // When launched as a subprocess, we expect our standard input and output to be the message stream, and standard error to be a console output stream.
        //
        // Immediately capture those into distinct file descriptors, and close the originals.
        let inputFD: FileDescriptor
        do {
            inputFD = try FileDescriptor.standardInput.duplicate()
        } catch {
            throw StubError.error("unable to dup input stream: \(error)")
        }

        // Rewire stdout to a stable file descriptor.
        let outputFD: FileDescriptor
        do {
            outputFD = try FileDescriptor.standardOutput.duplicate()
        } catch {
            throw StubError.error("unable to dup output stream: \(error)")
        }

        // https://learn.microsoft.com/en-us/cpp/c-runtime-library/text-and-binary-mode-file-i-o
        // "The stdin, stdout, and stderr streams always open in text mode by default", but these are used to carry Swift Build's binary I/O protocol, and therefore MUST be set to binary.
        do {
            try inputFD.setBinaryMode()
            try outputFD.setBinaryMode()
        } catch {
            throw StubError.error("unable to set I/O streams to binary mode: \(error)")
        }

        // Close and dup stdin to the null device
        let nullPath = Path.null
        let nullFd: FileDescriptor
        do {
            nullFd = try FileDescriptor.open(FilePath(nullPath.str), .readOnly)
        } catch {
            throw StubError.error("unable to open \(nullPath.str): \(error)")
        }

        // (dup2 closes its 2nd parameter)
        do {
            _ = try nullFd.duplicate(as: .standardInput)
        } catch {
            throw StubError.error("unable to dup \(nullPath.str) to stdin: \(error)")
        }

        // Now remap stdout to stderr, so normal print statements go to the console output stream.
        // (dup2 closes its 2nd parameter)
        do {
            _ = try FileDescriptor.standardError.duplicate(as: .standardOutput)
        } catch {
            throw StubError.error("unable to dup stderr to stdout: \(error)")
        }

        try await setupFileDescriptors(inputFD, outputFD)
    }
}
