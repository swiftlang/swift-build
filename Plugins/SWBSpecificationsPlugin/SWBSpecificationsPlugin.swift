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

import PackagePlugin
import Foundation

/// Used to compile .xcspec files in the SwiftPM build of Swift Build
@main struct SWBSpecificationsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let tool = try context.tool(named: "SWBSpecificationsCompiler")
        let enumerator = FileManager.default.enumerator(at: target.directoryURL.repaired, includingPropertiesForKeys: nil)
        var inputs: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if ["xcspec", "xcbuildrules"].contains(url.pathExtension) {
                inputs.append(url)
            }
        }
        return [
            .buildCommand(
                displayName: "SWBSpecificationsCompiler",
                executable: tool.url.repaired,
                arguments: ([context.pluginWorkDirectoryURL.repaired] + inputs).compactMap { $0.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) }},
                inputFiles: inputs,
                outputFiles: inputs.map { context.pluginWorkDirectoryURL.appending(component: $0.lastPathComponent).repaired })
        ]
    }
}

// https://github.com/swiftlang/swift-package-manager/issues/8001
extension Target {
    var directoryURL: URL {
        (self as! SwiftSourceModuleTarget).directoryURL.repaired
    }
}

// https://github.com/swiftlang/swift-package-manager/issues/6851
extension URL {
    var repaired: URL {
        #if os(Windows)
        // FIXME: It's a bug that SwiftPM is giving us a path without the drive root
        let driveLetter = String(FileManager.default.currentDirectoryPath.first!)
        let path = withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) } ?? ""
        return (path.hasPrefix("/") || path.hasPrefix("\\")) ? URL(fileURLWithPath: driveLetter + ":" + path) : self
        #else
        return self
        #endif
    }
}
