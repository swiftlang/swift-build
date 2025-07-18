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
    public let path: Path

    /// List of NDKs available in this SDK installation, sorted by version number from oldest to newest.
    @_spi(Testing) public let ndks: [NDK]

    public var latestNDK: NDK? {
        ndks.last
    }

    init(host: OperatingSystem, path: Path, fs: any FSProxy) throws {
        self.host = host
        self.path = path
        self.ndks = try NDK.findInstallations(host: host, sdkPath: path, fs: fs)
    }

    @_spi(Testing) public struct NDK: Equatable, Sendable {
        public static let minimumNDKVersion = Version(23)

        public let host: OperatingSystem
        public let path: Path
        public let version: Version
        public let abis: [String: ABI]
        public let deploymentTargetRange: DeploymentTargetRange

        init(host: OperatingSystem, path ndkPath: Path, version: Version, fs: any FSProxy) throws {
            self.host = host
            self.path = ndkPath
            self.version = version

            let metaPath = ndkPath.join("meta")

            guard #available(macOS 14, *) else {
                throw StubError.error("Unsupported macOS version")
            }

            if version < Self.minimumNDKVersion {
                throw StubError.error("Android NDK version at path '\(ndkPath.str)' is not supported (r\(Self.minimumNDKVersion.description) or later required)")
            }

            self.abis = try JSONDecoder().decode(ABIs.self, from: Data(fs.read(metaPath.join("abis.json"))), configuration: version).abis

            struct PlatformsInfo: Codable {
                let min: Int
                let max: Int
            }

            let platformsInfo = try JSONDecoder().decode(PlatformsInfo.self, from: Data(fs.read(metaPath.join("platforms.json"))))
            deploymentTargetRange = DeploymentTargetRange(min: platformsInfo.min, max: platformsInfo.max)
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

            @_spi(Testing) public struct LLVMTriple: Codable, Equatable, Sendable {
                public var arch: String
                public var vendor: String
                public var system: String
                public var environment: String

                var description: String {
                    "\(arch)-\(vendor)-\(system)-\(environment)"
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    let triple = try container.decode(String.self)
                    if let match = try #/(?<arch>.+)-(?<vendor>.+)-(?<system>.+)-(?<environment>.+)/#.wholeMatch(in: triple) {
                        self.arch = String(match.output.arch)
                        self.vendor = String(match.output.vendor)
                        self.system = String(match.output.system)
                        self.environment = String(match.output.environment)
                    } else {
                        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid triple string: \(triple)")
                    }
                }
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
                self.min_os_version = try container.decodeIfPresent(Int.self, forKey: .min_os_version) ?? {
                    if ndkVersion < Version(27) {
                        return 21 // min_os_version wasn't present prior to NDKr27, fill it in with 21, which is the appropriate value
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

        public var toolchainPath: Path {
            path.join("toolchains").join("llvm").join("prebuilt").join(hostTag)
        }

        public var sysroot: Path {
            toolchainPath.join("sysroot")
        }

        private var hostTag: String? {
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
                nil // unsupported host
            }
        }

        public static func findInstallations(host: OperatingSystem, sdkPath: Path, fs: any FSProxy) throws -> [NDK] {
            let ndkBasePath = sdkPath.join("ndk")
            guard fs.exists(ndkBasePath) else {
                return []
            }

            let ndks = try fs.listdir(ndkBasePath).map({ try Version($0) }).sorted()
            let supportedNdks = ndks.filter { $0 >= minimumNDKVersion }

            // If we have some NDKs but all of them are unsupported, try parsing them so that parsing fails and provides a more useful error. Otherwise, simply filter out and ignore the unsupported versions.
            let discoveredNdks = supportedNdks.isEmpty && !ndks.isEmpty ? ndks : supportedNdks

            return try discoveredNdks.map { ndkVersion in
                let ndkPath = ndkBasePath.join(ndkVersion.description)
                return try NDK(host: host, path: ndkPath, version: ndkVersion, fs: fs)
            }
        }
    }

    public static func findInstallations(host: OperatingSystem, fs: any FSProxy) async throws -> [AndroidSDK] {
        let defaultLocation: Path? = switch host {
        case .windows:
            // %LOCALAPPDATA%\Android\Sdk
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Android").appendingPathComponent("Sdk").filePath
        case .macOS:
            // ~/Library/Android/sdk
            try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Android").appendingPathComponent("sdk").filePath
        case .linux:
            // ~/Android/Sdk
            Path.homeDirectory.join("Android").join("Sdk")
        default:
            nil
        }

        if let path = defaultLocation, fs.exists(path) {
            return try [AndroidSDK(host: host, path: path, fs: fs)]
        }

        return []
    }
}
