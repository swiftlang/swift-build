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
import SWBMacro
import Foundation

public let initializePlugin: PluginInitializationFunction = { manager in
    manager.register(WebAssemblyPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(WebAssemblyPlatformExtension(), type: PlatformInfoExtensionPoint.self)
}

struct WebAssemblyPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBWebAssemblyPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    func specificationDomains() -> [String: [String]] {
        ["webassembly": ["generic-unix"]]
    }
}

struct WebAssemblyPlatformExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString("webassembly"),
                "Identifier": .plString("webassembly"),
                "Description": .plString("webassembly"),
                "FamilyName": .plString("WebAssembly"),
                "FamilyIdentifier": .plString("webassembly"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }

    func platformName(triple: LLVMTriple) -> String? {
        if triple.system.hasPrefix("wasi") {
            return "webassembly"
        }

        return nil
    }
}
