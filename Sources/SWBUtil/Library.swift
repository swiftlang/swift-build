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

import SWBCLibc
public import SWBLibc

#if canImport(System)
import System
#else
import SystemPackage
#endif

public enum Library: Sendable {
    /// Loads the dynamic library at the given `path`, returning a handle
    /// suitable for symbol lookups.
    ///
    /// - note: This function is and  **must** be `@_alwaysEmitIntoClient` due to the
    ///         behavior of `dlopen` on Apple platforms (and possibly other platforms).
    ///         `dlopen` searches the runpath search paths of the caller's image and the
    ///         main executable. This means that runpath search path resolution is
    ///         _incorrect_ if not emitted into the client (i.e. the image containing the
    ///         caller of this function) because it would otherwise use `SWBUtil`'s
    ///         runpath search paths instead of the caller's.
    @_alwaysEmitIntoClient
    public static func open(_ path: Path) throws -> LibraryHandle {
        #if os(Windows)
        guard let handle = path.withPlatformString(LoadLibraryW) else {
            throw LibraryOpenError(message: "LoadLibraryW returned \(GetLastError())")
        }
        return LibraryHandle(rawValue: handle)
        #else
        #if canImport(Darwin)
        let flags = RTLD_LAZY | RTLD_FIRST
        #else
        let flags = RTLD_LAZY
        #endif
        guard let handle = path.withPlatformString({ (p: UnsafePointer<CChar>) in dlopen(p, flags) }) else {
            #if os(Android)
            throw LibraryOpenError(message: String(cString: dlerror()!))
            #else
            throw LibraryOpenError(message: String(cString: dlerror()))
            #endif
        }
        return LibraryHandle(rawValue: handle)
        #endif
    }

    public static func lookup<T>(_ handle: LibraryHandle, _ symbol: String) -> T? {
        #if os(Windows)
        guard let ptr = GetProcAddress(handle.rawValue, symbol) else { return nil }
        #else
        guard let ptr = dlsym(handle.rawValue, symbol) else { return nil }
        #endif
        return unsafeBitCast(ptr, to: T.self)
    }

    public static func locate<T>(_ pointer: T.Type) -> Path {
        let outPointer: UnsafeMutablePointer<CInterop.PlatformChar>
        #if os(Windows)
        var handle: HMODULE?
        GetModuleHandleExW(DWORD(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT), unsafeBitCast(pointer, to: LPCWSTR?.self), &handle)
        let capacity = 260
        outPointer = .allocate(capacity: capacity)
        defer { outPointer.deallocate() }
        GetModuleFileNameW(handle, outPointer, DWORD(capacity))
        #else
        var info = Dl_info()
        #if os(Android)
        dladdr(unsafeBitCast(pointer, to: UnsafeMutableRawPointer.self), &info)
        outPointer = UnsafeMutablePointer(mutating: info.dli_fname!)
        #else
        dladdr(unsafeBitCast(pointer, to: UnsafeMutableRawPointer?.self), &info)
        outPointer = UnsafeMutablePointer(mutating: info.dli_fname)
        #endif
        #endif
        return Path(platformString: outPointer)
    }
}

public struct LibraryOpenError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public var description: String {
        message
    }

    @usableFromInline
    internal init(message: String) {
        self.message = message
    }
}

// Library handles just store an opaque reference to the dlopen/LoadLibrary-returned pointer, and so are Sendable in practice based on how they are used.
public struct LibraryHandle: @unchecked Sendable {
    #if os(Windows)
    @usableFromInline typealias PlatformHandle = HMODULE
    #else
    @usableFromInline typealias PlatformHandle = UnsafeMutableRawPointer
    #endif

    fileprivate let rawValue: PlatformHandle

    @usableFromInline
    internal init(rawValue: PlatformHandle) {
        self.rawValue = rawValue
    }
}
