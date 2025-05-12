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

@main
struct GenerateWindowsInstallerComponentGroups: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var librariesComponent = #"    <ComponentGroup Id="SwiftBuild" Directory="_usr_bin">\#n"#
        var resourcesComponents = ""
        var groupRefs = #"      <ComponentGroupRef Id="SwiftBuild" />\#n"#
        var directories = #"                <Directory Id="_usr_share_pm" Name="pm">\#n"#
        for target in context.package.targets.sorted(by: { $0.name < $1.name }).filter({ !["SWBTestSupport", "SwiftBuildTestSupport"].contains($0.name) }) {
            guard let sourceModule = target.sourceModule, sourceModule.kind == .generic else {
                continue
            }
            librariesComponent += #"""
                  <Component>
                    <File Source="$(ToolchainRoot)\usr\bin\\#(sourceModule.name).dll" />
                  </Component>
            
            """#

            let resources = sourceModule.sourceFiles.filter { resource in resource.type == .resource && ["xcspec", "xcbuildrules"].contains(resource.url.pathExtension) }
            if !resources.isEmpty {
                groupRefs += #"      <ComponentGroupRef Id="\#(sourceModule.name)Resources" />\#n"#
                directories += #"                  <Directory Id="_usr_share_pm_\#(sourceModule.name)" Name="SwiftBuild_\#(sourceModule.name).resources" />\#n"#
                resourcesComponents += #"    <ComponentGroup Id="\#(sourceModule.name)Resources" Directory="_usr_share_pm_\#(sourceModule.name)">\#n"#
                for resource in resources  {
                    resourcesComponents += #"""
                      <Component>
                        <File Source="$(ToolchainRoot)\usr\share\pm\SwiftBuild_\#(sourceModule.name).resources\\#(resource.url.lastPathComponent)" />
                      </Component>
                
                """#
                }
                resourcesComponents += "    </ComponentGroup>\n"
            }
        }
        librariesComponent += "    </ComponentGroup>\n"
        directories += "                </Directory>\n"

        print("Component Groups")
        print(String(repeating: "-", count: 80))
        print(librariesComponent)
        print(resourcesComponents)
        print("Group Refs")
        print(String(repeating: "-", count: 80))
        print(groupRefs)
        print("Directories")
        print(String(repeating: "-", count: 80))
        print(directories)
    }
}
