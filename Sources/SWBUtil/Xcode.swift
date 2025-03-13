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

public enum Xcode: Sendable {
    /// Get the path to the active developer directory, if possible.
    public static func getActiveDeveloperDirectoryPath() async throws -> Path {
        if let env = getEnvironmentVariable("DEVELOPER_DIR")?.nilIfEmpty {
            return Path(env)
        }

        let xcodeSelectPath = Path("/usr/bin/xcode-select")
        if !localFS.exists(xcodeSelectPath) {
            throw StubError.error("\(xcodeSelectPath.str) does not exist")
        }

        let environment = Environment.current.filter { $0.key == .developerDir }
        let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: xcodeSelectPath.str), arguments: ["-p"], environment: environment)
        if !executionResult.exitStatus.isSuccess {
            throw RunProcessNonZeroExitError(args: [xcodeSelectPath.str, "-p"], workingDirectory: nil, environment: environment, status: executionResult.exitStatus, stdout: ByteString(executionResult.stdout), stderr: ByteString(executionResult.stderr))
        }

        // If we got the location, extract the path.
        return Path(String(decoding: executionResult.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)).normalize()
    }
}

public struct XcodeVersionInfo: Sendable {
    public let shortVersion: Version
    public let productBuildVersion: ProductBuildVersion?

    /// Extracts the version info from a version.plist in an Xcode or Playgrounds installation at `versionPath`.
    ///
    /// - Returns: A tuple of the short version and ProductBuildVersion, or `nil` if the Xcode at `appPath` does not have a version.plist. Note that the ProductBuildVersion may also be `nil` even if the version.plist was present, as it can be missing in some cases.
    /// - Throws: If there was an error reading the version.plist file or parsing its contents.
    public static func versionInfo(versionPath: Path, fs: any FSProxy = localFS) throws -> XcodeVersionInfo? {
        struct VersionPlist: Decodable {
            let shortVersionString: String
            let productBuildVersion: String?

            enum CodingKeys: String, CodingKey {
                case shortVersionString = "CFBundleShortVersionString"
                case productBuildVersion = "ProductBuildVersion"
            }
        }

        guard fs.exists(versionPath) else {
            return nil
        }

        let versionStrings: VersionPlist
        do {
            versionStrings = try PropertyListDecoder().decode(VersionPlist.self, from: Data(fs.read(versionPath).bytes))
        } catch {
            throw StubError.error("Failed to decode version plist at '\(versionPath.str)': \(error.localizedDescription)")
        }
        let (shortVersion, productBuildVersion) = try (Version(versionStrings.shortVersionString), versionStrings.productBuildVersion.map(ProductBuildVersion.init))

        // <rdar://41211049> Guard against corrupt version info making its way into DTXcodeBuild and DTPlatformBuild
        if let productBuildVersion, productBuildVersion.major != shortVersion[0] {
            throw StubError.error("invalid content in '\(versionPath.str)' - ProductBuildVersion '\(productBuildVersion)' does not match CFBundleShortVersionString '\(shortVersion)' because their major version numbers differ (\(productBuildVersion.major) vs \(shortVersion[0])).")
        }

        return XcodeVersionInfo(shortVersion: shortVersion, productBuildVersion: productBuildVersion)
    }
}
