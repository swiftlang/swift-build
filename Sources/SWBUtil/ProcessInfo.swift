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
        #elseif os(FreeBSD)
        return .freebsd
        #elseif os(OpenBSD)
        return .openbsd
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

public struct LinuxDistribution: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case unknown
        case ubuntu
        case debian
        case amazon = "amzn"
        case centos
        case rhel
        case fedora
        case suse
        case alpine
        case arch

        /// The display name for the distribution kind
        public var displayName: String {
            switch self {
            case .unknown: return "Unknown Linux"
            case .ubuntu: return "Ubuntu"
            case .debian: return "Debian"
            case .amazon: return "Amazon Linux"
            case .centos: return "CentOS"
            case .rhel: return "Red Hat Enterprise Linux"
            case .fedora: return "Fedora"
            case .suse: return "SUSE"
            case .alpine: return "Alpine Linux"
            case .arch: return "Arch Linux"
            }
        }
    }

    public let kind: Kind
    public let version: String?

    public init(kind: Kind, version: String? = nil) {
        self.kind = kind
        self.version = version
    }

    /// The display name for the distribution including version if available
    public var displayName: String {
        if let version = version {
            return "\(kind.displayName) \(version)"
        } else {
            return kind.displayName
        }
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
    case freebsd
    case openbsd
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

    /// The distribution if this is a Linux operating system
    public var distribution: LinuxDistribution? {
        switch self {
        case .linux:
            return detectHostLinuxDistribution()
        default:
            return nil
        }
    }

    public var imageFormat: ImageFormat {
        switch self {
        case .macOS, .iOS, .tvOS, .watchOS, .visionOS:
            return .macho
        case .windows:
            return .pe
        case .linux, .freebsd, .openbsd, .android, .unknown:
            return .elf
        }
    }

    private func detectHostLinuxDistribution() -> LinuxDistribution? {
        return detectHostLinuxDistribution(fs: localFS)
    }

    /// Detects the Linux distribution by examining system files with an injected filesystem
    /// Start with the "generic" /etc/os-release then fallback
    /// to various distribution named files.
    public func detectHostLinuxDistribution(fs: any FSProxy) -> LinuxDistribution? {
        // Try /etc/os-release first (standard)
        let osReleasePath = Path("/etc/os-release")
        if fs.exists(osReleasePath) {
            if let osReleaseData = try? fs.read(osReleasePath),
               let osRelease = String(data: Data(osReleaseData.bytes), encoding: .utf8) {
                if let distribution = parseOSRelease(osRelease) {
                    return distribution
                }
            }
        }

        // Fallback to distribution-specific files
        let distributionFiles: [(String, LinuxDistribution.Kind)] = [
            ("/etc/ubuntu-release", .ubuntu),
            ("/etc/debian_version", .debian),
            ("/etc/amazon-release", .amazon),
            ("/etc/centos-release", .centos),
            ("/etc/redhat-release", .rhel),
            ("/etc/fedora-release", .fedora),
            ("/etc/SuSE-release", .suse),
            ("/etc/alpine-release", .alpine),
            ("/etc/arch-release", .arch),
        ]

        for (file, kind) in distributionFiles {
            if fs.exists(Path(file)) {
                return LinuxDistribution(kind: kind)
            }
        }

        return nil
    }

    /// Parses /etc/os-release content to determine distribution and version
    /// Fallback to just getting the distribution from specific files.
    private func parseOSRelease(_ content: String) -> LinuxDistribution? {
        let lines = content.components(separatedBy: .newlines)
        var id: String?
        var idLike: String?
        var versionId: String?

        // Parse out ID, ID_LIKE and VERSION_ID
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ID=") {
                id = String(trimmed.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("ID_LIKE=") {
                idLike = String(trimmed.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("VERSION_ID=") {
                versionId = String(trimmed.dropFirst(11)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        // Check ID first
        if let id = id {
            let kind: LinuxDistribution.Kind?
            switch id.lowercased() {
            case "ubuntu": kind = .ubuntu
            case "debian": kind = .debian
            case "amzn": kind = .amazon
            case "centos": kind = .centos
            case "rhel": kind = .rhel
            case "fedora": kind = .fedora
            case "suse", "opensuse", "opensuse-leap", "opensuse-tumbleweed": kind = .suse
            case "alpine": kind = .alpine
            case "arch": kind = .arch
            default: kind = nil
            }

            if let kind = kind {
                return LinuxDistribution(kind: kind, version: versionId)
            }
        }

        // Check ID_LIKE as fallback
        if let idLike = idLike {
            let likes = idLike.components(separatedBy: .whitespaces)
            for like in likes {
                let kind: LinuxDistribution.Kind?
                switch like.lowercased() {
                case "ubuntu": kind = .ubuntu
                case "debian": kind = .debian
                case "rhel", "fedora": kind = .rhel
                case "suse": kind = .suse
                case "arch": kind = .arch
                default: kind = nil
                }

                if let kind = kind {
                    return LinuxDistribution(kind: kind, version: versionId)
                }
            }
        }
        return nil
    }
}

public enum ImageFormat {
    case macho
    case elf
    case pe
    case wasm
}

extension ImageFormat {
    public var executableExtension: String {
        switch self {
        case .macho, .elf:
            return ""
        case .pe:
            return "exe"
        case .wasm:
            return "wasm"
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
        case .wasm:
            return "wasm"
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
        case .wasm:
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

    public var usesRpaths: Bool {
        switch self {
            case .macho, .elf:
                return true
            case .pe, .wasm:
                return false
        }
    }

    public var rpathOrigin: String? {
        switch self {
        case .macho:
            return "@loader_path"
        case .elf:
            return "$ORIGIN"
        default:
            return nil
        }
    }

    public var usesDsyms: Bool {
        switch self {
        case .macho:
            return true
        default:
            return false
        }
    }
}

extension FixedWidthInteger {
    fileprivate func orIfZero(_ other: Self) -> Self {
        return self != 0 ? self : other
    }
}

