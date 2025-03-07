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
}

struct WindowsPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBWindowsPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }
}

struct WindowsEnvironmentExtension: EnvironmentExtension {
    func additionalEnvironmentVariables(fs: any FSProxy) async throws -> [String: String] {
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            // Add the environment variable for the MSVC toolset for Swift and Clang to find it
            let vcToolsInstallDir = "VCToolsInstallDir"
            let installations = try await VSInstallation.findInstallations(fs: fs)
                .sorted(by: { $0.installationVersion > $1.installationVersion })
            if let latest = installations.first {
                let msvcDir = latest.installationPath.join("VC").join("Tools").join("MSVC")
                let versions = try fs.listdir(msvcDir).map { try Version($0) }.sorted { $0 > $1 }
                if let latestVersion = versions.first {
                    let dir = msvcDir.join(latestVersion.description).str
                    return [vcToolsInstallDir: dir]
                }
            }
        }
        return [:]
    }
}
