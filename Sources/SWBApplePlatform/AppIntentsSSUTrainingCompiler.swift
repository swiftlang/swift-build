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
import Foundation
import SWBMacro
public import SWBCore

final public class AppIntentsSSUTrainingCompilerSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.appintents-ssu-training"

    private func shouldConstructSsuTrainingTask(_ cbc: CommandBuildContext) -> Bool {
        guard cbc.producer.canConstructAppIntentsSSUTask else {
            return false
        }

        // For installLoc builds, we expect two input files named AppShortcuts.strings and Info.plist.
        if cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            guard cbc.inputs.count == 2 else {
                if cbc.inputs.count > 2 {
                    assertionFailure("AppIntents YAML Generation task construction was passed context with more than two input files.")
                } else {
                    assertionFailure("AppIntents YAML Generation task construction was passed context without required input files.")
                }
                return false
            }
        } else {
            guard cbc.inputs.count == 1 || cbc.inputs.count == 2 else {
                assertionFailure("AppIntents YAML Generation task construction was passed context without required input files.")
                return false
            }
        }

        let stringsFileType = cbc.producer.lookupFileType(identifier: "text.plist.strings")!
        let xcstringsFileType = cbc.producer.lookupFileType(identifier: "text.json.xcstrings")!
        let plistFileType = cbc.producer.lookupFileType(identifier: "text.plist")!

        if cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            guard cbc.inputs[0].fileType.conformsTo(stringsFileType) || cbc.inputs[0].fileType.conformsTo(xcstringsFileType),
                  cbc.inputs[0].absolutePath.basename.hasSuffix("InfoPlist.strings") ||
                    cbc.inputs[0].absolutePath.basename.hasSuffix("InfoPlist.xcstrings") else {
                assertionFailure("AppIntents YAML Generation task construction was passed context without InfoPlist.strings file.")
                return false
            }
        } else {
            guard cbc.inputs[0].fileType.conformsTo(plistFileType),
                  cbc.inputs[0].absolutePath.basename == "Info.plist" else {
                assertionFailure("AppIntents YAML Generation task construction was passed context without Info.plist file.")
                return false
            }
        }
        if cbc.inputs.count == 2 {
            guard cbc.inputs[1].fileType.conformsTo(stringsFileType) || cbc.inputs[1].fileType.conformsTo(xcstringsFileType),
                  ["AppShortcuts.strings", "AppShortcuts.xcstrings"].contains(cbc.inputs[1].absolutePath.basename) else {
                assertionFailure("AppIntents YAML Generation task construction was passed context without AppShortcuts.strings file.")
                return false
            }
        }

        return true
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        guard shouldConstructSsuTrainingTask(cbc) else {
            return
        }

        guard let resourcesDir = cbc.resourcesDir else {
            assertionFailure("Resources directory does not exist")
            return
        }

        var inputs: [any PlannedNode] = cbc.inputs.map { delegate.createNode($0.absolutePath) }
        let outputs: [any PlannedNode] = [cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("ssu/root.ssu.yaml")].map(delegate.createNode)
        var metadataDependencyFileListFiles = [String]()

        // Validate AppShortcuts strings/xcstrings if it is used as an input
        if inputs.count == 2 {
            // Workaround until we have rdar://93626172 (Re-enable AppIntentsMetadataProcessor outputs)
            let inputNodeIdentifier: String
            if let configuredTarget = cbc.producer.configuredTarget {
                inputNodeIdentifier = "ValidateAppShortcutStringsMetadata \(configuredTarget.guid) \(cbc.inputs[1].absolutePath.str)"
            } else {
                inputNodeIdentifier = "ValidateAppShortcutStringsMetadata \(cbc.inputs[1].absolutePath.str)"
            }
            let inputOrderingNode = delegate.createVirtualNode(inputNodeIdentifier) // Create the NL training task only if AppShortcuts.strings is validated
            inputs.append(inputOrderingNode)
        }

        if !cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            // Workaround until we have rdar://93626172 (Re-enable AppIntentsMetadataProcessor outputs)
            let inputOrderingNode = delegate.createVirtualNode("ExtractAppIntentsMetadata \(resourcesDir.join("Metadata.appintents").str )")
            inputs.append(inputOrderingNode)
        }

        let metadataFileListPath = cbc.scope.evaluate(BuiltinMacros.LM_AUX_INTENTS_METADATA_FILES_LIST_PATH)
        if !metadataFileListPath.isEmpty {
            metadataDependencyFileListFiles.append(metadataFileListPath.str)
            inputs.append(delegate.createNode(metadataFileListPath))
        }

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.LM_INTENTS_METADATA_FILES_LIST_PATH:
                return cbc.scope.table.namespace.parseLiteralStringList(metadataDependencyFileListFiles)
            default:
                return nil
            }
        }

        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)
        delegate.createTask(type: self,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs,
                            outputs: outputs,
                            action: nil,
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            enableSandboxing: enableSandboxing)
    }
}

