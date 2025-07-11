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

public import protocol Foundation.LocalizedError

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

public enum POSIX: Sendable {
    public static func getenv(_ name: String) throws -> String? {
        #if os(Windows)
        try name.withCString(encodedAs: CInterop.PlatformUnicodeEncoding.self) { wName in
            do {
                return try SWB_GetEnvironmentVariableW(wName)
            } catch let error as Win32Error where error.error == ERROR_ENVVAR_NOT_FOUND {
                return nil
            }
        }
        #else
        return SWBLibc.getenv(name).map { String(cString: $0) } ?? nil
        #endif
    }

    public static func setenv(_ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>, _ overwrite: Int32) throws {
        let nameString = String(cString: name)
        let valueString = String(cString: value)
        #if os(Windows)
        if overwrite == 0 {
            if nameString.withCString(encodedAs: CInterop.PlatformUnicodeEncoding.self, { GetEnvironmentVariableW($0, nil, 0) }) == 0 && GetLastError() != ERROR_ENVVAR_NOT_FOUND {
                throw POSIXError(errno, context: "GetEnvironmentVariableW", nameString)
            }
            return
        }
        guard nameString.withCString(encodedAs: CInterop.PlatformUnicodeEncoding.self, { nameWString in
            valueString.withCString(encodedAs: CInterop.PlatformUnicodeEncoding.self, { valueWString in
                SetEnvironmentVariableW(nameWString, valueWString)
            })
        }) else {
            throw POSIXError(errno, context: "SetEnvironmentVariableW", nameString, valueString)
        }
        #else
        let ret = SWBLibc.setenv(name, value, overwrite)
        if ret != 0 {
            throw POSIXError(errno, context: "setenv", nameString)
        }
        #endif
    }

    public static func unsetenv(_ name: UnsafePointer<CChar>) throws {
        let nameString = String(cString: name)
        #if os(Windows)
        guard nameString.withCString(encodedAs: CInterop.PlatformUnicodeEncoding.self, { SetEnvironmentVariableW($0, nil) }) else {
            throw POSIXError(errno, context: "SetEnvironmentVariableW", nameString)
        }
        #else
        let ret = SWBLibc.unsetenv(name)
        if ret != 0 {
            throw POSIXError(errno, context: "unsetenv", nameString)
        }
        #endif
    }
}

public struct POSIXError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let underlyingError: Errno
    public let context: String?
    public let arguments: [String]

    public var code: Int32 {
        underlyingError.rawValue
    }

    public init(_ code: Int32, context: String? = nil, _ arguments: [String]) {
        self.underlyingError = Errno(rawValue: code)
        self.context = context
        self.arguments = arguments
    }

    public init(_ code: Int32, context: String? = nil, _ arguments: String...) {
        self.init(code, context: context, arguments)
    }

    public var description: String {
        let end = "\(underlyingError.description) (\(code))"
        if let context {
            return "\(context)(\(arguments.joined(separator: ", "))): \(end)"
        }
        return end
    }

    public var errorDescription: String? {
        return description
    }
}

public func eintrLoop<T>(_ f: () throws -> T) throws -> T {
    while true {
        do {
            return try f()
        }
        catch let e as POSIXError where e.code == EINTR {
            continue
        }
    }
}
