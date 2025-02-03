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

package import SWBCore
package import SWBUtil

// FIXME: We should have a better way to map these to targets/products.
func auxiliaryFileCommand(_ path: Path) -> String {
    switch path.fileExtension {
    case "hmap":
        break // Headermaps are per target, so we can't add any information here.
    case "LinkFileList":
        return "produces product '\(path.basenameWithoutSuffix)'"
    case "modulemap", "yaml": // VFS or module overlay
        if let moduleName = potentialModuleNameFromPath(path) {
            return "produces module '\(moduleName)'"
        }
    default:
        break
    }

    // Output file maps are per target, so we can't add any information here.
    if path.str.hasSuffix("-OutputFileMap.json") {
        return "has write command with output \(path.str)"
    }

    if path.str.hasSuffix("_vers.c") {
        let productName = path.basename.dropLast("_vers.c".count)
        return "produces product \(productName)"
    }

    return "has write command with output \(path.str)"
}

func potentialModuleNameFromPath(_ path: Path) -> String? {
    let parent = path.dirname.basename
    return parent.hasSuffix(".build") ? String(parent.dropLast(".build".count)) : nil
}

package enum DiagnosticType {
    case dependencyCycle
    case multipleProducers
}

package enum RuleInfoFormattable {
    case task(any ExecutableTask)
    case string(String)
}

extension Collection where Element == RuleInfoFormattable {
    package func rawRuleInfo(workspace: Workspace? = nil) -> [String] {
        var commands = map({ (formattable: Element) -> String in
            switch formattable {
            case let .task(task):
                return task.formattedRuleInfo(workspace: workspace)
            case let .string(string):
                return string
            }
        })

        if allSatisfy({
            switch $0 {
            case let .task(task):
                return task.ruleInfo.first == "RuleScriptExecution"
            case .string:
                return false
            }
        }) {
            commands.append("Consider making this custom build rule architecture-neutral by unchecking 'Run once per architecture' in Build Rules, or ensure that it produces distinct output file paths for each architecture and variant combination.")
        }

        return commands
    }

    package func richFormattedRuleInfo(workspace: Workspace? = nil) -> [Diagnostic] {
        return rawRuleInfo(workspace: workspace).map({ command -> Diagnostic in
            Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData(command))
        })
    }
}

extension ExecutableTask {
    var isShellScript: Bool {
        return ruleInfo.last?.hasSuffix(".sh") == true
    }

    package func formattedRuleInfo(workspace: Workspace? = nil) -> String {
        return formattedRuleInfo(for: .multipleProducers, workspace: workspace) ?? ruleInfo.joined(separator: " ")
    }

    package func formattedRuleInfo(for type: DiagnosticType, workspace: Workspace? = nil) -> String? {
        var command = ": " + ruleInfo.joined(separator: " ")

        // Add prefix with target name if available
        var prefix: String
        if let target = forTarget {
            prefix = "Target '\(target.target.name)'"

            if type == .multipleProducers, let project = workspace?.project(for: target.target) {
                prefix += " (project '\(project.name)')"
            }
        } else {
            prefix = "Command"
        }

        // For most rule info types, we construct a sentence-style command description to return.  For a few we'll return the raw rule info.
        switch ruleInfo.first {
        case "CompileC", "DataModelCompile", "CompileAssetCatalog":
            if ruleInfo.count >= 3 {
                command = "has compile command with input '\(ruleInfo[2])'"
            }
        case "CompileAssetCatalogVariant":
            if ruleInfo.count >= 4 {
                command = "has compile command with input '\(ruleInfo[3])'"
            }

        case "CompileXIB", "CompileMetalFile", "CompileStoryboard":
            if ruleInfo.count >= 2 {
                command = "has compile command with input '\(ruleInfo[1])'"
            }

        case "CompileSwiftSources":
            command = "has compile command for Swift source files"

        case "SwiftDriver":
            command = "has Swift driver planning command for Swift source files"

        case "SwiftDriver Compilation Requirements":
            command = "has Swift tasks blocking downstream compilation"

        case "SwiftDriver Compilation":
            command = "has Swift tasks not blocking downstream targets"

        // Filter build directory related tasks
        case "CreateBuildDirectory":
            return nil

        case "CreateUniversalBinary":
            if ruleInfo.count >= 2 {
                command = "has a command with output '\(ruleInfo[1])'"
            }

        // Filter gate tasks
        case "Gate":
            return nil

        case "GenerateDSYMFile":
            if ruleInfo.count >= 2 {
                command = "has a command with output '\(ruleInfo[1])'"
            }

        case "GenerateSwiftModule":
            command = "has command to generate a Swift module"

        case "Ld":
            if ruleInfo.count >= 2 {
                command = "has link command with output '\(ruleInfo[1])'"
            }

        case "MkDir":
            if ruleInfo.count >= 2 {
                command = "has create directory command with output '\(ruleInfo[1])'"
            }

        case "CopyPlistFile", "CopyStringsFile", "CopyPNGFile", "CopyTiffFile":
            if ruleInfo.count == 3 {
                command = "has copy command from '\(ruleInfo[2])' to '\(ruleInfo[1])'"
            }

        case "Copy", "CpHeader", "CpResource":
            if ruleInfo.count == 3 {
                command = "has copy command from '\(ruleInfo[2])' to '\(ruleInfo[1])'"
            }

        // Relationships to shell scripts are always of "generated by" kind.
        case "PhaseScriptExecution":
            prefix = "That command depends on command in \(prefix):"
            if ruleInfo.count >= 2 {
                command = "script phase “\(ruleInfo[1])”"
            }

        case "Preprocess":
            if ruleInfo.count >= 2 {
                command = "has preprocess command with input '\(ruleInfo[1])'"
            }

        case "ProcessInfoPlistFile":
            if ruleInfo.count >= 2 {
                command = "has process command with output '\(ruleInfo[1])'"
            }

        case "ProcessSDKImports":
            if ruleInfo.count >= 2 {
                command = "has process command with output '\(ruleInfo[1])'"
            }

        case "ProcessPCH++", "ProcessPCH":
            if ruleInfo.count >= 3 {
                command = "has process command with input '\(ruleInfo[2])'"
            }

        case "RuleScriptExecution":
            if ruleInfo.count >= 4 {
                command = "has custom build rule with input '\(ruleInfo[ruleInfo.count - 3])'"
            }

        case "SymLink":
            if ruleInfo.count == 3 {
                command = "has symlink command from '\(ruleInfo[1])' to '\(ruleInfo[2])'"
            }

        case "WriteAuxiliaryFile":
            // Do not display writing of shell script files.
            if isShellScript {
                return nil
            } else {
                if let file = ruleInfo.last {
                    // Dependency cycles may omit unnecessary commands.
                    switch type {
                    case .dependencyCycle:
                        if Path(file).fileExtension == "modulemap" {
                            command = "has write command with output \(file)"
                        } else {
                            command = ""
                        }
                    case .multipleProducers:
                        command = auxiliaryFileCommand(Path(file))
                    }
                }
            }

        default:
            // If we don't recognize the rule info type, then we will just return the raw command's rule info string.
            break
        }

        // If we didn't end up with any command, then just return the prefix (either "Target '<name>'" or "Command").
        if command.isEmpty {
            return prefix
        }

        // Insert whitespace for "sentence-style" command descriptions.
        if !command.starts(with: ":") {
            command = " \(command)"
        }

        // Return the prefix and the command.
        return "\(prefix)\(command)"
    }
}
