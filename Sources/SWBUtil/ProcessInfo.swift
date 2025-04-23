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
import SWBLibc

#if os(Windows)
#if canImport(System)
import System
#else
import SystemPackage
#endif
#endif

// Defined in System.framework's sys/resource.h, but not available to Swift
fileprivate let IOPOL_TYPE_VFS_HFS_CASE_SENSITIVITY: Int32 = 1

extension ProcessInfo {
    public var userID: Int {
        #if os(Windows)
        return 0
        #else
        return Int(getuid())
        #endif
    }

    public var effectiveUserID: Int {
        #if os(Windows)
        return 0
        #else
        return Int(geteuid())
        #endif
    }

    public var groupID: Int {
        #if os(Windows)
        return 0
        #else
        return Int(getgid())
        #endif
    }

    public var effectiveGroupID: Int {
        #if os(Windows)
        return 0
        #else
        return Int(getegid())
        #endif
    }

    public var shortUserName: String {
        #if os(Windows)
        var capacity = UNLEN + 1
        let pointer = UnsafeMutablePointer<CInterop.PlatformChar>.allocate(capacity: Int(capacity))
        defer { pointer.deallocate() }
        if GetUserNameW(pointer, &capacity) {
            return String(platformString: pointer)
        }
        return ""
        #else
        let uid = geteuid().orIfZero(getuid())
        return (getpwuid(uid)?.pointee.pw_name).map { String(cString: $0) } ?? String(uid)
        #endif
    }

    public var shortGroupName: String {
        #if os(Windows)
        return ""
        #else
        let gid = getegid().orIfZero(getgid())
        return (getgrgid(gid)?.pointee.gr_name).map { String(cString: $0) } ?? String(gid)
        #endif
    }

    public var cleanEnvironment: [String: String] {
        // https://github.com/apple/swift-foundation/issues/847
        environment.filter { !$0.key.hasPrefix("=") }
    }

    public var isRunningUnderFilesystemCaseSensitivityIOPolicy: Bool {
        #if os(macOS)
        return getiopolicy_np(IOPOL_TYPE_VFS_HFS_CASE_SENSITIVITY, IOPOL_SCOPE_PROCESS) == 1
        #else
        return false
        #endif
    }

    public func hostOperatingSystem() throws -> OperatingSystem {
        #if os(Windows)
        return .windows
        #elseif os(Linux)
        return .linux
        #else
        if try FileManager.default.isReadableFile(atPath: systemVersionPlistURL.filePath.str) {
            switch try systemVersion().productName {
            case "Mac OS X", "macOS":
                return .macOS
            case "iPhone OS":
                return .iOS(simulator: simulatorRoot != nil)
            case "Apple TVOS":
                return .tvOS(simulator: simulatorRoot != nil)
            case "Watch OS":
                return .watchOS(simulator: simulatorRoot != nil)
            case "xrOS":
                return .visionOS(simulator: simulatorRoot != nil)
            default:
                break
            }
        }
        return .unknown
        #endif
    }
}

public enum OperatingSystem: Hashable, Sendable {
    case macOS
    case iOS(simulator: Bool)
    case tvOS(simulator: Bool)
    case watchOS(simulator: Bool)
    case visionOS(simulator: Bool)
    case windows
    case linux
    case android
    case unknown

    /// Whether the operating system is any Apple platform except macOS.
    public var isAppleEmbedded: Bool {
        switch self {
        case .iOS, .tvOS, .watchOS, .visionOS:
            return true
        default:
            return false
        }
    }

    public var isSimulator: Bool {
        switch self {
        case let .iOS(simulator), let .tvOS(simulator), let .watchOS(simulator), let .visionOS(simulator):
            return simulator
        default:
            return false
        }
    }

    public var imageFormat: ImageFormat {
        switch self {
        case .macOS, .iOS, .tvOS, .watchOS, .visionOS:
            return .macho
        case .windows:
            return .pe
        case .linux, .android, .unknown:
            return .elf
        }
    }
}

public enum ImageFormat {
    case macho
    case elf
    case pe
}

extension ImageFormat {
    public var executableExtension: String {
        switch self {
        case .macho, .elf:
            return ""
        case .pe:
            return "exe"
        }
    }

    public func executableName(basename: String) -> String {
        executableExtension.nilIfEmpty.map { [basename, $0].joined(separator: ".") } ?? basename
    }

    public var dynamicLibraryExtension: String {
        switch self {
        case .macho:
            return "dylib"
        case .elf:
            return "so"
        case .pe:
            return "dll"
        }
    }

    public var requiresSwiftAutolinkExtract: Bool {
        switch self {
        case .macho:
            return false
        case .elf:
            return true
        case .pe:
            return false
        }
    }

    public var requiresSwiftModulewrap: Bool {
        switch self {
        case .macho:
            return false
        default:
            return true
        }
    }
}

extension FixedWidthInteger {
    fileprivate func orIfZero(_ other: Self) -> Self {
        return self != 0 ? self : other
    }
}
