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

package import SWBUtil

import struct Foundation.CharacterSet
import struct Foundation.Data
import struct Foundation.URL

package struct InstalledXcode: Sendable {
    package let developerDirPath: Path
    package init(developerDirPath: Path) { self.developerDirPath = developerDirPath }

    package static func currentlySelected() async throws -> InstalledXcode {
        return try await InstalledXcode(developerDirPath: Xcode.getActiveDeveloperDirectoryPath())
    }

    package var versionPath: Path { return developerDirPath.dirname.join("version.plist") }

    package func find(_ tool: String, toolchain: String? = nil) async throws -> Path {
        let toolchainArgs = toolchain.map { ["--toolchain", $0] } ?? []
        return try await Path(xcrun(["-f", tool] + toolchainArgs).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package func xcrun(_ args: [String], workingDirectory: Path? = nil, redirectStderr: Bool = true) async throws -> String {
        return try await runProcessWithDeveloperDirectory(["/usr/bin/xcrun"] + args, workingDirectory: workingDirectory, overrideDeveloperDirectory: self.developerDirPath.str, redirectStderr: redirectStderr)
    }

    package func productBuildVersion() throws -> ProductBuildVersion {
        guard let versionInfo = try XcodeVersionInfo.versionInfo(versionPath: versionPath) else {
            throw StubError.error("No version.plist at \(versionPath.str)")
        }
        guard let productBuildVersion = versionInfo.productBuildVersion else {
            throw StubError.error("Expected ProductBuildVersion in \(versionPath.str)")
        }
        return productBuildVersion
    }

    package func productBuildVersion(sdkCanonicalName: String) async throws -> ProductBuildVersion {
        let commandLine = ["xcodebuild", "-version", "-sdk", sdkCanonicalName, "ProductBuildVersion"]
        do {
            return try await ProductBuildVersion(xcrun(commandLine, redirectStderr: false).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        catch {
            throw StubError.error("\(error.localizedDescription) Command line: \(commandLine.joined(separator: " "))")
        }
    }

    package func productSDKVersion(sdkCanonicalName: String) async throws -> Version {
        let commandLine = ["xcodebuild", "-version", "-sdk", sdkCanonicalName, "SDKVersion"]
        do {
            return try await Version(xcrun(commandLine, redirectStderr: false).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        catch {
            throw StubError.error("\(error.localizedDescription) Command line: \(commandLine.joined(separator: " "))")
        }
    }

    package func hasSDK(sdkCanonicalName: String) async -> Bool {
        do {
            _ = try await PropertyList.fromPath(Path(xcrun(["xcodebuild", "-version", "-sdk", sdkCanonicalName, "Path"], redirectStderr: false).trimmingCharacters(in: .whitespacesAndNewlines)).join("SDKSettings.plist"), fs: localFS)
            return true
        } catch {
            return false
        }
    }
}
