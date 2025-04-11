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

import SWBUtil
public import SWBCore
import SWBMacro

public final class ResMergerLinkerSpec : GenericLinkerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.pbx.linkers.resmerger"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Create the task for the collector merge.
        let tmpOutputPath = cbc.scope.evaluate(BuiltinMacros.REZ_COLLECTOR_DIR).join(cbc.inputs.regionVariantName ?? (cbc.scope.evaluate(BuiltinMacros.PRODUCT_NAME) + ".rsrc"))
        let inputs = cbc.inputs.map { $0.absolutePath.str }

        let environment: EnvironmentBindings = environmentFromSpec(cbc, delegate)
        do {
            var commandLine = [resolveExecutablePath(cbc, Path("ResMerger")).str]

            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_TYPE, in: cbc.scope) { ["-fileType", $0] }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_CREATOR, in: cbc.scope) { ["-fileCreator", $0] }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_TYPE_ARG, in: cbc.scope) { $0 }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_CREATOR_ARG, in: cbc.scope) { $0 }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.OTHER_RESMERGERFLAGS, in: cbc.scope) { $0 }

            let resmergerSourcesFork = cbc.scope.evaluate(BuiltinMacros.RESMERGER_SOURCES_FORK)
            if resmergerSourcesFork == "data" {
                commandLine += ["-srcIs", "DF"]
            }
            else if resmergerSourcesFork == "resource" {
                commandLine += ["-srcIs", "RSRC"]
            }

            commandLine += ["-dstIs", "DF"]
            commandLine += inputs
            commandLine += ["-o", tmpOutputPath.str]

            let execDescription = resolveExecutionDescription(cbc, delegate) { decl in
                switch decl {
                case BuiltinMacros.OutputPath, BuiltinMacros.OutputFile:
                    return cbc.scope.namespace.parseLiteralString(tmpOutputPath.str)
                default: return nil
                }
            }
            delegate.createTask(type: self, ruleInfo: ["ResMergerCollector", tmpOutputPath.str], commandLine: commandLine, environment: environment, workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }), outputs: [tmpOutputPath], action: nil, execDescription:  execDescription, enableSandboxing: enableSandboxing)
        }

        // Create the task for the product merge.
        do {
            var outputPath = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).normalize()
            let region = cbc.inputs.regionVariantPathComponent
            if !region.isEmpty {
                outputPath = outputPath.join(region.dropLast()).join("Localized.rsrc")
            } else {
                outputPath = outputPath.join(cbc.scope.evaluate(BuiltinMacros.PRODUCT_NAME) + ".rsrc")
            }

            var commandLine = [resolveExecutablePath(cbc, Path("ResMerger")).str]
            commandLine.append(tmpOutputPath.str)

            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_TYPE, in: cbc.scope) { ["-fileType", $0] }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_CREATOR, in: cbc.scope) { ["-fileCreator", $0] }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_TYPE_ARG, in: cbc.scope) { $0 }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.MACOS_CREATOR_ARG, in: cbc.scope) { $0 }
            commandLine += BuiltinMacros.ifSet(BuiltinMacros.OTHER_RESMERGERFLAGS, in: cbc.scope) { $0 }

            let resmergerSourcesFork = cbc.scope.evaluate(BuiltinMacros.RESMERGER_SOURCES_FORK)
            if resmergerSourcesFork == "data" {
                commandLine += ["-srcIs", "DF"]
            }
            else if resmergerSourcesFork == "resource" {
                commandLine += ["-srcIs", "RSRC"]
            }

            commandLine += ["-dstIs", "DF"]
            commandLine += ["-o", outputPath.str]

            let execDescription = resolveExecutionDescription(cbc, delegate) { decl in
                switch decl {
                case BuiltinMacros.OutputPath, BuiltinMacros.OutputFile:
                    return cbc.scope.namespace.parseLiteralString(tmpOutputPath.str)
                default: return nil
                }
            }
            delegate.createTask(type: self, ruleInfo: ["ResMergerProduct", outputPath.str], commandLine: commandLine, environment: environment, workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [tmpOutputPath], outputs: [outputPath], action: nil, execDescription: execDescription, enableSandboxing: enableSandboxing)
        }
    }
}
