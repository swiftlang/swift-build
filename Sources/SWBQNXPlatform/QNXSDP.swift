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

struct QNXSDP: Sendable {
    public let host: OperatingSystem
    public let path: Path
    public let configurationPath: Path
    public let version: Version?

    public init(host: OperatingSystem, path: Path, configurationPath: Path) async throws {
        self.host = host
        self.path = path
        let hostPath = Self.hostPath(host: host, path: path)
        self.hostPath = hostPath
        let sysroot = path.join("target").join("qnx")
        self.sysroot = sysroot
        self.configurationPath = configurationPath

        var environment: Environment = [
            "QNX_TARGET": sysroot.str,
            "QNX_CONFIGURATION_EXCLUSIVE": configurationPath.str,
        ]
        if let hostPath {
            environment["QNX_HOST"] = hostPath.str
        }
        self.environment = environment

        self.version = try await {
            if let compilerPath = hostPath?.join("usr").join("bin").join(host.imageFormat.executableName(basename: "qcc")) {
                let output = try await Process.getMergedOutput(url: URL(fileURLWithPath: compilerPath.str), arguments: ["-dM", "E", "-x", "c", "-c", Path.null.str, "-o", Path.null.str], environment: environment)
                if output.exitStatus.isSuccess, !output.output.isEmpty {
                    let prefix = "#define __QNX__ "
                    if let versionString = String(decoding: output.output, as: UTF8.self).split(separator: "\n").map(String.init).first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count), let version = Int(versionString) {
                        switch version {
                        case 0...999:
                            return Version(UInt(version / 100 % 10), UInt(version / 10 % 10), UInt(version % 10))
                        default:
                            return nil
                        }
                    }
                }
            }
            return nil
        }()
    }

    /// Equivalent to `QNX_TARGET`.
    public let sysroot: Path

    /// Equivalent to `QNX_HOST`.
    public let hostPath: Path?

    public let environment: Environment

    private static func hostPath(host: OperatingSystem, path: Path) -> Path? {
        switch host {
        case .windows:
            path.join("host").join("win64").join("x86_64")
        case .macOS:
            path.join("host").join("darwin").join("x86_64") // only supported in QNX SDP 7
        case .linux:
            path.join("host").join("linux").join("x86_64")
        default:
            nil // unsupported host
        }
    }

    public static func findInstallations(host: OperatingSystem, fs: any FSProxy) async throws -> [QNXSDP] {
        var searchPaths = [Path.homeDirectory]
        if host == .windows {
            if let systemDrive = getEnvironmentVariable("SystemDrive") {
                searchPaths.append(Path(systemDrive + Path.pathSeparatorString))
            }
        } else {
            searchPaths.append(Path("/opt"))
        }

        for searchPath in searchPaths where fs.exists(searchPath) {
            // Swallow errors in case the directory is inaccessible (e.g. HOME could be /root and running as a non-root user)
            if let searchPathContents = try? fs.listdir(searchPath) {
                if let path = try searchPathContents.filter({ try #/qnx[0-9]{3}/#.wholeMatch(in: $0) != nil }).sorted().reversed().map({ searchPath.join($0) }).first(where: { fs.exists($0) }) {
                    return try await [QNXSDP(host: host, path: path, configurationPath: getEnvironmentVariable("QNX_CONFIGURATION_EXCLUSIVE").map { Path($0) } ?? Path.homeDirectory.join(".qnx"))]
                }
            }
        }

        return []
    }
}
