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
    manager.register(UniversalPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
}

struct UniversalPlatformSpecsExtension: SpecificationsExtension {
    func specificationClasses() -> [any SpecIdentifierType.Type] {
        [
            CopyPlistFileSpec.self,
            CopyStringsFileSpec.self,
            CppToolSpec.self,
            LexCompilerSpec.self,
            YaccCompilerSpec.self,
        ]
    }

    func specificationImplementations() -> [any SpecImplementationType.Type] {
        [
            DiffToolSpec.self,
        ]
    }

    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBUniversalPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    // Allow locating the sole remaining `.xcbuildrules` file.
    func specificationSearchPaths(resourceSearchPaths: [Path]) -> [URL] {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBUniversalPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)?.resourceURL.map { [$0] } ?? []
    }
}
