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

import SWBCore
@_spi(Testing) import SWBWindowsPlatform
import SWBUtil

extension VSInstallation.Component.ID {
    static let visualCppBuildTools_x86_x64 = Self("Microsoft.VisualStudio.Component.VC.Tools.x86.x64")
    static let visualCppBuildTools_arm = Self("Microsoft.VisualStudio.Component.VC.Tools.ARM")
    static let visualCppBuildTools_arm64 = Self("Microsoft.VisualStudio.Component.VC.Tools.ARM64")
    static let visualCppBuildTools_arm64ec = Self("Microsoft.VisualStudio.Component.VC.Tools.ARM64EC")
}

extension Core {
    func hasVisualStudioComponent(_ name: VSInstallation.Component.ID) async throws -> Bool {
        try await pluginManager.extensions(of: EnvironmentExtensionPoint.self).compactMap({ $0 as? WindowsEnvironmentExtension }).first?.plugin.cachedVSInstallations().first?.packages.contains(where: { $0.id == name }) == true
    }
}
