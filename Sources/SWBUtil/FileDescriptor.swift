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

private import SWBCSupport
private import SWBLibc

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

extension FileDescriptor {
    public static func _pipe2(options: _PipeOptions) throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
        var fds: (Int32, Int32) = (-1, -1)
        return try withUnsafeMutablePointer(to: &fds) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 2) { fds in
                valueOrErrno(retryOnInterrupt: false) {
                    swb_pipe2(fds, options.rawValue)
                }.map { _ in (FileDescriptor(rawValue: fds[0]), FileDescriptor(rawValue: fds[1])) }
            }
        }.get()
    }

    public func _duplicate3(as target: FileDescriptor, retryOnInterrupt: Bool = true, options: _DuplicateOptions) throws -> FileDescriptor {
        try valueOrErrno(retryOnInterrupt: retryOnInterrupt) {
            return swb_dup3(self.rawValue, target.rawValue, options.rawValue)
        }.map(FileDescriptor.init(rawValue:)).get()
    }
}

#if os(Windows)
fileprivate let O_CLOEXEC: CInt = 0

extension FileDescriptor.OpenOptions {
    public static var closeOnExec: FileDescriptor.OpenOptions { .init(rawValue: O_CLOEXEC) }
}
#endif

extension FileDescriptor {
    public struct _PipeOptions: OptionSet, Sendable, Hashable, Codable {
        public var rawValue: CInt

        public init(rawValue: CInt) {
            self.rawValue = rawValue
        }

        public static var closeOnExec: Self { .init(rawValue: O_CLOEXEC) }
    }

    public struct _DuplicateOptions: OptionSet, Sendable, Hashable, Codable {
        public var rawValue: CInt

        public init(rawValue: CInt) {
            self.rawValue = rawValue
        }

        public static var closeOnExec: Self { .init(rawValue: O_CLOEXEC) }
    }
}

fileprivate func valueOrErrno<I: FixedWidthInteger>(
    _ i: I
) -> Result<I, Errno> {
    i == -1 ? .failure(Errno(rawValue: errno)) : .success(i)
}

fileprivate func valueOrErrno<I: FixedWidthInteger>(
    retryOnInterrupt: Bool, _ f: () -> I
) -> Result<I, Errno> {
    repeat {
        switch valueOrErrno(f()) {
        case .success(let r): return .success(r)
        case .failure(let err):
            guard retryOnInterrupt && err == .interrupted else { return .failure(err) }
            break
        }
    } while true
}
