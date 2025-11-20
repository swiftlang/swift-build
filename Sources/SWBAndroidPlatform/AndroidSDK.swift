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

public import SWBUtil
public import Foundation

@_spi(Testing) public struct AndroidSDK: Sendable {
    public let host: OperatingSystem
    public let path: AbsolutePath
    private let ndkInstallations: NDK.Installations

    /// List of NDKs available in this SDK installation, sorted by version number from oldest to newest.
    @_spi(Testing) public var ndks: [NDK] {
        ndkInstallations.ndks
    }

    public var preferredNDK: NDK? {
        ndkInstallations.preferredNDK ?? ndks.last
    }

    init(host: OperatingSystem, path: AbsolutePath, fs: any FSProxy) throws {
        self.host = host
        self.path = path
        self.ndkInstallations = try NDK.findInstallations(host: host, sdkPath: path, fs: fs)
    }

    @_spi(Testing) public struct NDK: Equatable, Sendable {
        public static let minimumNDKVersion = Version(23)

        public let host: OperatingSystem
        public let path: AbsolutePath
        public let version: Version
        public let abis: [String: ABI]
        public let deploymentTargetRange: DeploymentTargetRange

        @_spi(Testing) public init(host: OperatingSystem, path ndkPath: AbsolutePath, fs: any FSProxy) throws {
            self.host = host
            self.path = ndkPath
            self.toolchainPath = try AbsolutePath(validating: path.path.join("toolchains").join("llvm").join("prebuilt").join(Self.hostTag(host)))
            self.sysroot = try AbsolutePath(validating: toolchainPath.path.join("sysroot"))

            let propertiesFile = ndkPath.path.join("source.properties")
            guard fs.exists(propertiesFile) else {
                throw Error.notAnNDK(ndkPath)
            }

            self.version = try NDK.Properties(data: Data(fs.read(propertiesFile))).revision

            let metaPath = ndkPath.path.join("meta")

            if version < Self.minimumNDKVersion {
                throw Error.unsupportedVersion(path: ndkPath, minimumVersion: Self.minimumNDKVersion)
            }

            self.abis = try JSONDecoder().decode(ABIs.self, from: Data(fs.read(metaPath.join("abis.json"))), configuration: version).abis

            struct PlatformsInfo: Codable {
                let min: Int
                let max: Int
            }

            let platformsInfo = try JSONDecoder().decode(PlatformsInfo.self, from: Data(fs.read(metaPath.join("platforms.json"))))
            deploymentTargetRange = DeploymentTargetRange(min: platformsInfo.min, max: platformsInfo.max)
        }

        public enum Error: Swift.Error, CustomStringConvertible, Sendable {
            case notAnNDK(AbsolutePath)
            case unsupportedVersion(path: AbsolutePath, minimumVersion: Version)
            case noSupportedVersions(minimumVersion: Version)

            public var description: String {
                switch self {
                case let .notAnNDK(path):
                    "Package at path '\(path.path.str)' is not an Android NDK (no source.properties file)"
                case let .unsupportedVersion(path, minimumVersion):
                    "Android NDK version at path '\(path.path.str)' is not supported (r\(minimumVersion.description) or later required)"
                case let .noSupportedVersions(minimumVersion):
                    "All installed NDK versions are not supported (r\(minimumVersion.description) or later required)"
                }
            }
        }

        struct Properties {
            let properties: JavaProperties
            let revision: Version

            init(data: Data) throws {
                properties = try .init(data: data)
                guard properties["Pkg.Desc"] == "Android NDK" else {
                    throw StubError.error("Package is not an Android NDK")
                }
                revision = try Version(properties["Pkg.BaseRevision"] ?? properties["Pkg.Revision"] ?? "")
            }
        }

        struct ABIs: DecodableWithConfiguration {
            let abis: [String: ABI]

            init(from decoder: any Decoder, configuration: Version) throws {
                struct DynamicCodingKey: CodingKey {
                    var stringValue: String

                    init?(stringValue: String) {
                        self.stringValue = stringValue
                    }

                    let intValue: Int? = nil

                    init?(intValue: Int) {
                        nil
                    }
                }
                let container = try decoder.container(keyedBy: DynamicCodingKey.self)
                abis = try Dictionary(uniqueKeysWithValues: container.allKeys.map { try ($0.stringValue, container.decode(ABI.self, forKey: $0, configuration: configuration)) })
            }
        }

        @_spi(Testing) public struct ABI: DecodableWithConfiguration, Equatable, Sendable {
            @_spi(Testing) public enum Bitness: Int, Codable, Equatable, Sendable {
                case bits32 = 32
                case bits64 = 64
            }

            public let bitness: Bitness
            public let `default`: Bool
            public let deprecated: Bool
            public let proc: String
            public let arch: String
            public let triple: String
            public let llvm_triple: LLVMTriple
            public let min_os_version: Int

            enum CodingKeys: String, CodingKey {
                case bitness
                case `default` = "default"
                case deprecated
                case proc
                case arch
                case triple
                case llvm_triple = "llvm_triple"
                case min_os_version = "min_os_version"
            }

            public init(from decoder: any Decoder, configuration ndkVersion: Version) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.bitness = try container.decode(Bitness.self, forKey: .bitness)
                self.default = try container.decode(Bool.self, forKey: .default)
                self.deprecated = try container.decode(Bool.self, forKey: .deprecated)
                self.proc = try container.decode(String.self, forKey: .proc)
                self.arch = try container.decode(String.self, forKey: .arch)
                self.triple = try container.decode(String.self, forKey: .triple)
                self.llvm_triple = try container.decode(LLVMTriple.self, forKey: .llvm_triple)
                self.min_os_version =
                    try container.decodeIfPresent(Int.self, forKey: .min_os_version)
                    ?? {
                        if ndkVersion < Version(27) {
                            return 21  // min_os_version wasn't present prior to NDKr27, fill it in with 21, which is the appropriate value
                        } else {
                            throw DecodingError.valueNotFound(Int.self, .init(codingPath: container.codingPath, debugDescription: "No value associated with key \(CodingKeys.min_os_version) (\"\(CodingKeys.min_os_version.rawValue)\")."))
                        }
                    }()
            }
        }

        @_spi(Testing) public struct DeploymentTargetRange: Equatable, Sendable {
            public let min: Int
            public let max: Int
        }

        public let toolchainPath: AbsolutePath
        public let sysroot: AbsolutePath

        private static func hostTag(_ host: OperatingSystem) -> String? {
            switch host {
            case .windows:
                // Also works on Windows on ARM via Prism binary translation.
                "windows-x86_64"
            case .macOS:
                // Despite the x86_64 tag in the Darwin name, these are universal binaries including arm64.
                "darwin-x86_64"
            case .linux:
                // Also works on non-x86 archs via binfmt support and qemu (or Rosetta on Apple-hosted VMs).
                "linux-x86_64"
            default:
                nil  // unsupported host
            }
        }

        public struct Installations: Sendable {
            private let preferredIndex: Int?
            public let ndks: [NDK]

            init(preferredIndex: Int? = nil, ndks: [NDK]) {
                self.preferredIndex = preferredIndex
                self.ndks = ndks
            }

            public var preferredNDK: NDK? {
                preferredIndex.map { ndks[$0] } ?? ndks.only
            }
        }

        public static func findInstallations(host: OperatingSystem, sdkPath: AbsolutePath, fs: any FSProxy) throws -> Installations {
            if let overridePath = NDK.environmentOverrideLocation {
                return try Installations(ndks: [NDK(host: host, path: overridePath, fs: fs)])
            }

            let ndkBasePath = sdkPath.path.join("ndk")
            guard fs.exists(ndkBasePath) else {
                return Installations(ndks: [])
            }

            var hadUnsupportedVersions: Bool = false
            let ndks = try fs.listdir(ndkBasePath).compactMap({ subdir in
                do {
                    return try NDK(host: host, path: AbsolutePath(validating: ndkBasePath.join(subdir)), fs: fs)
                } catch Error.notAnNDK(_) {
                    return nil
                } catch Error.unsupportedVersion(_, _) {
                    hadUnsupportedVersions = true
                    return nil
                }
            }).sorted(by: \.version)

            // If we have some NDKs but all of them are unsupported, provide a more useful error. Otherwise, simply filter out and ignore the unsupported versions.
            if ndks.isEmpty && hadUnsupportedVersions {
                throw Error.noSupportedVersions(minimumVersion: Self.minimumNDKVersion)
            }

            // Respect Debian alternatives
            let preferredIndex: Int?
            if sdkPath == AndroidSDK.defaultDebianLocation, let ndkLinkPath = AndroidSDK.NDK.defaultDebianLocation {
                preferredIndex = try ndks.firstIndex(where: { try $0.path.path == fs.realpath(ndkLinkPath.path) })
            } else {
                preferredIndex = nil
            }

            return Installations(preferredIndex: preferredIndex, ndks: ndks)
        }
    }

    public static func findInstallations(host: OperatingSystem, fs: any FSProxy) async throws -> [AndroidSDK] {
        var paths: [AbsolutePath] = []
        if let path = AndroidSDK.environmentOverrideLocation {
            paths.append(path)
        }
        if let path = try AndroidSDK.defaultAndroidStudioLocation(host: host) {
            paths.append(path)
        }
        if let path = AndroidSDK.defaultDebianLocation, host == .linux {
            paths.append(path)
        }
        return try paths.compactMap { path in
            guard fs.exists(path.path) else {
                return nil
            }
            return try AndroidSDK(host: host, path: path, fs: fs)
        }
    }
}

extension AndroidSDK.NDK {
    /// The location of the Android NDK based on the `ANDROID_NDK_ROOT` environment variable (falling back to the deprecated but well known `ANDROID_NDK_HOME`).
    /// - seealso: [Configuring NDK Path](https://github.com/android/ndk-samples/wiki/Configure-NDK-Path#terminologies)
    internal static var environmentOverrideLocation: AbsolutePath? {
        (getEnvironmentVariable("ANDROID_NDK_ROOT") ?? getEnvironmentVariable("ANDROID_NDK_HOME"))?.nilIfEmpty.map { AbsolutePath($0) } ?? nil
    }

    /// Location of the Android NDK installed by the `google-android-ndk-*-installer` family of packages available in Debian 13 "Trixie" and Ubuntu 24.04 "Noble".
    /// These packages are available in non-free / multiverse and multiple versions can be installed simultaneously.
    fileprivate static var defaultDebianLocation: AbsolutePath? {
        AbsolutePath("/usr/lib/android-ndk")
    }
}

fileprivate extension AndroidSDK {
    /// The location of the Android SDK based on the `ANDROID_HOME` environment variable (falling back to the deprecated but well known `ANDROID_SDK_ROOT`).
    /// - seealso: [Android environment variables](https://developer.android.com/tools/variables)
    static var environmentOverrideLocation: AbsolutePath? {
        (getEnvironmentVariable("ANDROID_HOME") ?? getEnvironmentVariable("ANDROID_SDK_ROOT"))?.nilIfEmpty.map { AbsolutePath($0) } ?? nil
    }

    static func defaultAndroidStudioLocation(host: OperatingSystem) throws -> AbsolutePath? {
        switch host {
        case .windows:
            // %LOCALAPPDATA%\Android\Sdk
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Android").appendingPathComponent("Sdk").absoluteFilePath
        case .macOS:
            // ~/Library/Android/sdk
            try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Android").appendingPathComponent("sdk").absoluteFilePath
        case .linux:
            // ~/Android/Sdk
            try AbsolutePath(validating: Path.homeDirectory.join("Android").join("Sdk"))
        default:
            nil
        }
    }

    /// Location of the Android SDK installed by the `google-*` family of packages available in Debian 13 "Trixie" and Ubuntu 24.04 "Noble".
    /// These packages are available in non-free / multiverse and multiple versions can be installed simultaneously.
    static var defaultDebianLocation: AbsolutePath? {
        AbsolutePath("/usr/lib/android-sdk")
    }
}
