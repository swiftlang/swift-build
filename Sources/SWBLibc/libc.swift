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

#if canImport(Darwin)
@_exported import Darwin.C
#elseif os(Windows)
@_exported import ucrt
@_exported import CRT
@_exported import WinSDK
#elseif canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#elseif canImport(Android)
@_exported import Android
#else
#error("Missing libc or equivalent")
#endif
@_exported import SWBCLibc

// Stub method to avoid no debug symbol warning from compiler,
// and avoid a TAPI mismatch from compiler optimizations
// potentially removing profiling symbols.
public func swb_libc_anchor() -> Never {
    preconditionFailure()
}
