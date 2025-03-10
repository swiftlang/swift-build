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

import SWBUtil
import Foundation

struct AndroidSDK: Sendable {
    public let host: OperatingSystem
    public let path: Path
    public let ndkVersion: Version?

    init(host: OperatingSystem, path: Path, fs: any FSProxy) throws {
        self.host = host
        self.path = path

        let ndkBasePath = path.join("ndk")
        if fs.exists(ndkBasePath) {
            self.ndkVersion = try fs.listdir(ndkBasePath).map { try Version($0) }.max()
        } else {
            self.ndkVersion = nil
        }

        if let ndkVersion {
            let ndkPath = ndkBasePath.join(ndkVersion.description)
            let metaPath = ndkPath.join("meta")

            self.abis = try JSONDecoder().decode([String: ABI].self, from: Data(fs.read(metaPath.join("abis.json"))))

            struct PlatformsInfo: Codable {
                let min: Int
                let max: Int
            }

            let platformsInfo = try JSONDecoder().decode(PlatformsInfo.self, from: Data(fs.read(metaPath.join("platforms.json"))))
            self.ndkPath = ndkPath
            deploymentTargetRange = (platformsInfo.min, platformsInfo.max)
        } else {
            ndkPath = nil
            deploymentTargetRange = nil
            abis = nil
        }
    }

    struct ABI: Codable {
        enum Bitness: Int, Codable {
            case bits32 = 32
            case bits64 = 64
        }

        struct LLVMTriple: Codable {
            let arch: String
            let vendor: String
            let system: String
            let environment: String

            var description: String {
                "\(arch)-\(vendor)-\(system)-\(environment)"
            }

            init(from decoder: any Decoder) throws {
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

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(description)
            }
        }

        let bitness: Bitness
        let `default`: Bool
        let deprecated: Bool
        let proc: String
        let arch: String
        let triple: String
        let llvm_triple: LLVMTriple
        let min_os_version: Int
    }

    public let abis: [String: ABI]?

    public let deploymentTargetRange: (min: Int, max: Int)?

    public let ndkPath: Path?

    public var toolchainPath: Path? {
        ndkPath?.join("toolchains").join("llvm").join("prebuilt").join(hostTag)
    }

    public var sysroot: Path? {
        toolchainPath?.join("sysroot")
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
