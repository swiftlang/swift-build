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

import Foundation
import SWBMacro
import SWBUtil

/// Decodable representation of a .xcbuildrules file's on-disk format.
struct BuildRuleFile: Codable {
    let name: String
    let fileTypeIdent: String
    let compilerSpecIdent: String
    let action: Action

    enum Action {
        case taskAction
        case scriptAction(ScriptAction)
    }

    struct ScriptAction: Codable {
        let filePatterns: String
        let scriptContents: String
        let inputFilesItems: [String]?
        let inputFileListsItems: [String]?
        let outputFileListsItems: [String]?
        let outputFilesItems: [String]
        let runOncePerArchitecture: Bool?

        private enum CodingKeys: String, CodingKey {
            case filePatterns = "FilePatterns"
            case scriptContents = "Script"
            case inputFilesItems = "InputFiles"
            case inputFileListsItems = "InputFileLists"
            case outputFileListsItems = "OutputFileLists"
            case outputFilesItems = "OutputFiles"
            case runOncePerArchitecture = "RunOncePerArchitecture"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case fileTypeIdent = "FileType"
        case compilerSpecIdent = "CompilerSpec"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.fileTypeIdent = try container.decode(String.self, forKey: .fileTypeIdent)
        self.compilerSpecIdent = try container.decode(String.self, forKey: .compilerSpecIdent)

        if compilerSpecIdent == BuildRule_CompilerIsShellScriptIdentifier {
            self.action = try .scriptAction(.init(from: decoder))

            // Only file pattern input specifiers are supported in the .xcbuildrules format.
            assert(fileTypeIdent == BuildRule_FileTypeIsPatternIdentifier)
        } else {
            self.action = .taskAction
        }
    }
}

extension Core {
    func createRule(buildRule: BuildRuleFile, platform: Platform?, scope: MacroEvaluationScope, namespace: MacroNamespace) throws -> (any BuildRuleCondition, any BuildRuleAction) {
        switch buildRule.action {
        case .taskAction:
            return try createSpecBasedBuildRule(.fileType(identifier: buildRule.fileTypeIdent), buildRule.compilerSpecIdent, platform: platform)
        case let .scriptAction(scriptAction):
            // FIXME: <rdar://problem/29304140> Adopt the new API when it's available rather than doing this naive split.
            let filePatterns: [MacroStringExpression] = scriptAction.filePatterns.split(separator: " ").map({ namespace.parseString(String($0)) })

            let outputFiles = scriptAction.outputFilesItems.map { namespace.parseString($0) }
            let inputFiles = scriptAction.inputFilesItems?.map { namespace.parseString($0) } ?? []

            let inputFileLists = scriptAction.inputFileListsItems?.map { namespace.parseString($0) } ?? []
            let outputFileLists = scriptAction.outputFileListsItems?.map { namespace.parseString($0) } ?? []

            // FIXME: Presently we don't parse OutputFilesCompilerFlags.
            let outputFilesCompilerFlags: [MacroStringListExpression]? = nil

            // FIXME: Presently we don't parse DependencyInfo.
            let dependencyInfo: DependencyInfoFormat? = nil

            let runOncePerArchitecture = scriptAction.runOncePerArchitecture ?? true

            let outputs = outputFiles.enumerated().map { (i, expr) -> (MacroStringExpression, MacroStringListExpression?) in
                if let flags = outputFilesCompilerFlags, i < flags.count {
                    return (expr, flags[i])
                } else {
                    return (expr, nil)
                }
            }

            // Use the name of the build rule mangled into a C identifier as the build rule GUID. This _should_ be unique.
            return try createShellScriptBuildRule(buildRule.name.asLegalCIdentifier, buildRule.name, .patterns(filePatterns), scriptAction.scriptContents, inputFiles, inputFileLists, outputs, outputFileLists, dependencyInfo, runOncePerArchitecture, platform: platform, scope: scope)
        }
    }
}
