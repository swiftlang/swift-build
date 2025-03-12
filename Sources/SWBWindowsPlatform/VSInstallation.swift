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

import Foundation
public import SWBUtil
import SWBCore

public struct VSInstallation: Decodable, Sendable {
    public struct Component: Decodable, Sendable {
        public struct ID: Decodable, Sendable, RawRepresentable {
            public let rawValue: String

            public init(_ string: String) {
                self.rawValue = string
            }

            public init?(rawValue: String) {
                self.rawValue = rawValue
            }

            public init(from decoder: any Swift.Decoder) throws {
                rawValue = try String(from: decoder)
            }
        }

        public let id: Component.ID
    }

    public let installationPath: Path
    public let installationVersion: Version
    public let packages: [Component]

    /// Returns a list of all Visual Studio installations on the system, ordered from newest version and last installed to oldest.
    ///
    /// This includes both full Visual Studio {Community, Professional, Enterprise} installations as well as Visual Studio Build Tools.
    public static func findInstallations(fs: any FSProxy) async throws -> [VSInstallation] {
        guard let vswhere = try vswherePath(fs: fs) else {
            return []
        }
        let args = [
            "-products", "*",
            "-legacy",
            "-prerelease",
            "-sort",
            "-format", "json",
            "-include", "packages",
            "-utf8",
        ]
        let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: vswhere.str), arguments: args)
        guard executionResult.exitStatus.isSuccess else {
            throw RunProcessNonZeroExitError(args: args, workingDirectory: nil, environment: [:], status: executionResult.exitStatus, stdout: ByteString(executionResult.stdout), stderr: ByteString(executionResult.stderr))
        }
        return try JSONDecoder().decode([VSInstallation].self, from: executionResult.stdout)
    }

    private static func vswherePath(fs: any FSProxy) throws -> Path? {
        var paths: [Path] = []
        if let path = try POSIX.getenv("PATH") {
            paths.append(contentsOf: path.split(separator: Path.pathEnvironmentSeparator).map(Path.init).filter {
                // PATH may contain unexpanded shell variable references
                $0.isAbsolute
            })
        }
        if let programFilesX86 = URL.programFilesX86?.appending(components: "Microsoft Visual Studio", "Installer") {
            // This is a fixed location that will be maintained, according to the vswhere documentation.
            try paths.append(programFilesX86.filePath)
        }
        return StackedSearchPath(paths: paths, fs: fs).findExecutable(operatingSystem: .windows, basename: "vswhere")
    }
}
