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
import SWBCore
import Foundation

@PluginExtensionSystemActor public func initializePlugin(_ manager: PluginManager) {
    manager.register(WindowsPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(WindowsEnvironmentExtension(), type: EnvironmentExtensionPoint.self)
    manager.register(WindowsPlatformExtension(), type: PlatformInfoExtensionPoint.self)
}

struct WindowsPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles() -> Bundle? {
        .module
    }
}

private func findLatestInstallDirectory(fs: any FSProxy) async throws -> Path? {
    if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
        let installations = try await VSInstallation.findInstallations(fs: fs)
            .sorted(by: { $0.installationVersion > $1.installationVersion })
        if let latest = installations.first {
            let msvcDir = latest.installationPath.join("VC").join("Tools").join("MSVC")
            let versions = try fs.listdir(msvcDir).map { try Version($0) }.sorted { $0 > $1 }
            if let latestVersion = versions.first {
                let dir = msvcDir.join(latestVersion.description).str
                return Path(dir)
            }
        }
    }
    return nil
}

struct WindowsEnvironmentExtension: EnvironmentExtension {
    func additionalEnvironmentVariables(fs: any FSProxy) async throws -> [String: String] {
        // Add the environment variable for the MSVC toolset for Swift and Clang to find it
        let vcToolsInstallDir = "VCToolsInstallDir"
        guard let dir = try? await findLatestInstallDirectory(fs: fs) else {
            return [:]
        }
        return [vcToolsInstallDir: dir.str]
    }
}

struct WindowsPlatformExtension: PlatformInfoExtension {
    public func additionalPlatformExecutableSearchPaths(platformName: String, platformPath: Path, fs: any FSProxy) async -> [Path] {
        guard let dir = try? await findLatestInstallDirectory(fs: fs) else {
            return []
        }
        if Architecture.hostStringValue == "aarch64" {
            return [dir.join("bin/Hostarm64/arm64")]
        } else {
            return [dir.join("bin/Hostx64/x64")]
        }
    }
}
